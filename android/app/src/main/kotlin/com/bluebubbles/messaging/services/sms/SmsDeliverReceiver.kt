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
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (msgs.isEmpty()) return

        val address = msgs[0].displayOriginatingAddress ?: ""
        val body = msgs.joinToString("") { it.displayMessageBody ?: "" }
        val date = System.currentTimeMillis()

        val providerId = SmsProvider.insertInbox(context, address, body, date)
        Log.d(Constants.logTag, "SMS_DELIVER from $address (${body.length} chars) -> id $providerId")

        // Post a notification natively so it fires even if the Flutter engine
        // isn't alive (app killed/background).
        SmsNotifications.notify(context, address, body)

        val payload = mapOf(
            "providerId" to providerId, "address" to address, "body" to body,
            "date" to date, "read" to false, "isFromMe" to false, "type" to "sms",
        )
        runCatching { MethodCallHandler.invokeMethod("sms-received", payload) }
    }
}
