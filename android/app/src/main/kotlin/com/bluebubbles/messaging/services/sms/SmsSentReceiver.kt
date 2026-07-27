package com.bluebubbles.messaging.services.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler

/**
 * Receives the send result PendingIntent broadcast from [SmsSender]. On
 * success it records the message in the Sent box and reports status to Dart.
 */
class SmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != SmsSender.ACTION_SMS_SENT) return
        val messageId = intent.getStringExtra(SmsSender.EXTRA_MESSAGE_ID) ?: return
        val ok = resultCode == Activity.RESULT_OK
        val status = if (ok) "sent" else "failed"

        if (ok) {
            val address = intent.getStringExtra(SmsSender.EXTRA_ADDRESS) ?: ""
            val body = intent.getStringExtra(SmsSender.EXTRA_BODY) ?: ""
            val date = intent.getLongExtra(SmsSender.EXTRA_DATE, System.currentTimeMillis())
            runCatching { SmsProvider.insertSent(context, address, body, date) }
        }
        Log.d(Constants.logTag, "SMS sent status for $messageId: $status")
        runCatching {
            MethodCallHandler.invokeMethod("sms-sent-status", mapOf("messageId" to messageId, "status" to status))
        }
    }
}
