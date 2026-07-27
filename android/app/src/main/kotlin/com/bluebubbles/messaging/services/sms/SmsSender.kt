package com.bluebubbles.messaging.services.sms

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.telephony.SmsManager
import android.util.Log
import com.bluebubbles.messaging.Constants

/**
 * Sends an SMS via the system radio and (as default app) records it in the
 * Sent box. Success/failure is reported back to Dart via the sent-status
 * broadcast → [SmsSentReceiver] → method channel.
 */
object SmsSender {

    const val ACTION_SMS_SENT = "com.bluebubbles.messaging.SMS_SENT"
    const val EXTRA_MESSAGE_ID = "messageId"
    const val EXTRA_ADDRESS = "address"
    const val EXTRA_BODY = "body"
    const val EXTRA_DATE = "date"

    /** messageId is the caller's temp id, echoed back with the sent status. */
    fun send(context: Context, messageId: String, address: String, body: String) {
        val sms = context.getSystemService(SmsManager::class.java)
        if (sms == null) {
            Log.e(Constants.logTag, "SmsSender: no SmsManager")
            return
        }
        val date = System.currentTimeMillis()
        val intent = Intent(ACTION_SMS_SENT).setPackage(context.packageName).apply {
            putExtra(EXTRA_MESSAGE_ID, messageId)
            putExtra(EXTRA_ADDRESS, address)
            putExtra(EXTRA_BODY, body)
            putExtra(EXTRA_DATE, date)
        }
        val sentPI = PendingIntent.getBroadcast(
            context, messageId.hashCode(), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        try {
            val parts = sms.divideMessage(body)
            if (parts.size <= 1) {
                sms.sendTextMessage(address, null, body, sentPI, null)
            } else {
                val pis = ArrayList<PendingIntent>(parts.size).apply { repeat(parts.size) { add(sentPI) } }
                sms.sendMultipartTextMessage(address, null, parts, pis, null)
            }
            Log.i(Constants.logTag, "SmsSender: sending $messageId to $address (${parts.size} part(s))")
        } catch (e: Exception) {
            Log.e(Constants.logTag, "SmsSender: send failed for $messageId", e)
        }
    }
}
