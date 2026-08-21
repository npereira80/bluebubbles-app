package com.bluebubbles.messaging.services.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SmsManager
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
        if (ok) {
            Log.d(Constants.logTag, "SMS sent status for $messageId: sent")
        } else {
            // The result code is the only thing that says *why*, and every cause
            // has a different fix: no service is transient, and being refused for
            // not holding the SMS role is permanent on this device.
            Log.e(Constants.logTag, "SMS send failed for $messageId: ${describeResult(resultCode)}")
        }
        runCatching {
            MethodCallHandler.invokeMethod("sms-sent-status", mapOf("messageId" to messageId, "status" to status))
        }
    }

    /**
     * Name the SmsManager result code.
     *
     * Worth spelling out rather than printing a bare integer: the codes above 20
     * are the ones that mean "this device will never send this way", and they read
     * identically to a transient radio failure otherwise.
     */
    private fun describeResult(code: Int): String = when (code) {
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "GENERIC_FAILURE ($code)"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "RADIO_OFF ($code)"
        SmsManager.RESULT_ERROR_NULL_PDU -> "NULL_PDU ($code)"
        SmsManager.RESULT_ERROR_NO_SERVICE -> "NO_SERVICE ($code)"
        SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "LIMIT_EXCEEDED ($code)"
        SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE -> "FDN_CHECK_FAILURE ($code)"
        SmsManager.RESULT_ERROR_SHORT_CODE_NOT_ALLOWED -> "SHORT_CODE_NOT_ALLOWED ($code)"
        SmsManager.RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED -> "SHORT_CODE_NEVER_ALLOWED ($code)"
        SmsManager.RESULT_RADIO_NOT_AVAILABLE -> "RADIO_NOT_AVAILABLE ($code)"
        SmsManager.RESULT_NETWORK_REJECT -> "NETWORK_REJECT ($code)"
        SmsManager.RESULT_INVALID_ARGUMENTS -> "INVALID_ARGUMENTS ($code)"
        SmsManager.RESULT_INVALID_STATE -> "INVALID_STATE ($code)"
        SmsManager.RESULT_NO_MEMORY -> "NO_MEMORY ($code)"
        SmsManager.RESULT_INVALID_SMS_FORMAT -> "INVALID_SMS_FORMAT ($code)"
        SmsManager.RESULT_SYSTEM_ERROR -> "SYSTEM_ERROR ($code)"
        SmsManager.RESULT_MODEM_ERROR -> "MODEM_ERROR ($code)"
        SmsManager.RESULT_NETWORK_ERROR -> "NETWORK_ERROR ($code)"
        SmsManager.RESULT_ENCODING_ERROR -> "ENCODING_ERROR ($code)"
        SmsManager.RESULT_INVALID_SMSC_ADDRESS -> "INVALID_SMSC_ADDRESS ($code)"
        SmsManager.RESULT_OPERATION_NOT_ALLOWED -> "OPERATION_NOT_ALLOWED ($code)"
        SmsManager.RESULT_INTERNAL_ERROR -> "INTERNAL_ERROR ($code)"
        SmsManager.RESULT_NO_RESOURCES -> "NO_RESOURCES ($code)"
        SmsManager.RESULT_CANCELLED -> "CANCELLED ($code)"
        SmsManager.RESULT_REQUEST_NOT_SUPPORTED -> "REQUEST_NOT_SUPPORTED ($code)"
        SmsManager.RESULT_NO_BLUETOOTH_SERVICE -> "NO_BLUETOOTH_SERVICE ($code)"
        SmsManager.RESULT_INVALID_BLUETOOTH_ADDRESS -> "INVALID_BLUETOOTH_ADDRESS ($code)"
        SmsManager.RESULT_BLUETOOTH_DISCONNECTED -> "BLUETOOTH_DISCONNECTED ($code)"
        SmsManager.RESULT_UNEXPECTED_EVENT_STOP_SENDING -> "UNEXPECTED_EVENT_STOP_SENDING ($code)"
        SmsManager.RESULT_SMS_BLOCKED_DURING_EMERGENCY -> "SMS_BLOCKED_DURING_EMERGENCY ($code)"
        SmsManager.RESULT_SMS_SEND_RETRY_FAILED -> "SMS_SEND_RETRY_FAILED ($code)"
        SmsManager.RESULT_REMOTE_EXCEPTION -> "REMOTE_EXCEPTION ($code)"
        SmsManager.RESULT_NO_DEFAULT_SMS_APP -> "NO_DEFAULT_SMS_APP ($code)"
        SmsManager.RESULT_RIL_RADIO_NOT_AVAILABLE -> "RIL_RADIO_NOT_AVAILABLE ($code)"
        SmsManager.RESULT_RIL_SMS_SEND_FAIL_RETRY -> "RIL_SMS_SEND_FAIL_RETRY ($code)"
        SmsManager.RESULT_RIL_NETWORK_REJECT -> "RIL_NETWORK_REJECT ($code)"
        SmsManager.RESULT_RIL_MODEM_ERR -> "RIL_MODEM_ERR ($code)"
        SmsManager.RESULT_RIL_NO_RESOURCES -> "RIL_NO_RESOURCES ($code)"
        SmsManager.RESULT_RIL_REQUEST_NOT_SUPPORTED -> "RIL_REQUEST_NOT_SUPPORTED ($code)"
        SmsManager.RESULT_RIL_SIM_ABSENT -> "RIL_SIM_ABSENT ($code)"
        else -> "unknown ($code)"
    }
}
