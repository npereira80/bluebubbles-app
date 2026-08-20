package com.bluebubbles.messaging.services.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler

/**
 * Default-app SMS delivery. As the default SMS app we receive SMS_DELIVER and
 * are responsible for **persisting** the message to the provider, then we
 * notify Dart (best-effort, if the engine is alive; otherwise Dart catches it
 * on next provider backfill).
 */
class SmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // One line per delivery, deliberately kept: when SMS "doesn't work" on an
        // OEM ROM, the only question that matters first is whether the broadcast
        // reached us at all, and nothing else in the system answers it.
        Log.i(Constants.logTag, "SMS_DELIVER received (action=${intent.action})")

        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: run {
            Log.e(Constants.logTag, "SMS_DELIVER: no PDUs in the intent")
            return
        }
        if (msgs.isEmpty()) {
            Log.e(Constants.logTag, "SMS_DELIVER: empty message array")
            return
        }

        val address = msgs[0].displayOriginatingAddress ?: ""
        val body = msgs.joinToString("") { it.displayMessageBody ?: "" }
        val date = System.currentTimeMillis()

        // Persisting must not be able to lose the message. As the default SMS app
        // we are the only thing writing this to the provider, so an insert that
        // throws used to take the notification and the Dart hand-off down with
        // it — the text simply never existed. Some OEM ROMs (vivo OriginOS among
        // them) do reject or alter writes to content://sms from a non-system app.
        val providerId = runCatching { SmsProvider.insertInbox(context, address, body, date) }
            .onFailure { Log.e(Constants.logTag, "SMS_DELIVER: provider insert failed", it) }
            .getOrNull() ?: -1L

        // Post a notification natively so it fires even if the Flutter engine
        // isn't alive (app killed/background).
        runCatching { SmsNotifications.notify(context, address, body) }
            .onFailure { Log.e(Constants.logTag, "SMS_DELIVER: notification failed", it) }

        val payload = mapOf(
            "providerId" to providerId, "address" to address, "body" to body,
            "date" to date, "read" to false, "isFromMe" to false, "type" to "sms",
        )
        runCatching { MethodCallHandler.invokeMethod("sms-received", payload) }
    }
}
