package com.bluebubbles.messaging.services.sms

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
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

    /**
     * An SmsManager bound to the SIM that is actually active, rather than to
     * whatever subscription the system considers default.
     *
     * getSystemService(SmsManager::class.java) targets the default SMS
     * subscription. On a dual-SIM or eSIM phone that can easily be a slot with no
     * SIM in it, or one with no service, and the send then fails with
     * GENERIC_FAILURE despite the phone showing full signal — the same symptom as
     * a ROM refusing the send, which is what makes it worth ruling out explicitly.
     *
     * Falls back to the default when there is exactly one subscription or the
     * list can't be read, which is the single-SIM case and was always correct.
     */
    private fun smsManagerForActiveSim(context: Context): SmsManager? {
        val default = context.getSystemService(SmsManager::class.java)
        return try {
            val sm = context.getSystemService(SubscriptionManager::class.java) ?: return default
            val subs = sm.activeSubscriptionInfoList ?: return default
            if (subs.size <= 1) return default

            // More than one active subscription: pick the one the system uses for
            // SMS if it is genuinely active, else just the first active one.
            val defaultSmsSub = SubscriptionManager.getDefaultSmsSubscriptionId()
            val chosen = subs.firstOrNull { it.subscriptionId == defaultSmsSub } ?: subs.first()
            Log.i(Constants.logTag, "SmsSender: using subscription ${chosen.subscriptionId} of ${subs.size}")
            default?.createForSubscriptionId(chosen.subscriptionId) ?: default
        } catch (e: Exception) {
            Log.w(Constants.logTag, "SmsSender: could not resolve the active subscription", e)
            default
        }
    }

    /** messageId is the caller's temp id, echoed back with the sent status. */
    fun send(context: Context, messageId: String, address: String, body: String) {
        val sms = smsManagerForActiveSim(context)
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
            Log.i(Constants.logTag, "SmsSender: sending $messageId (${parts.size} part(s))")
        } catch (e: Exception) {
            Log.e(Constants.logTag, "SmsSender: send failed for $messageId", e)
        }
    }
}
