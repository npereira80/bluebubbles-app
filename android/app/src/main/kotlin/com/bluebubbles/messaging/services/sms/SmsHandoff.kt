package com.bluebubbles.messaging.services.sms

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hand an outgoing SMS to whichever app holds the SMS role, prefilled.
 *
 * The last resort for a phone that has the SIM but whose ROM refuses our sends.
 * vivo's China build returns GENERIC_FAILURE from SmsManager for an app that
 * doesn't hold the SMS role, and protects that role and its own Messages app
 * from every ADB route. The usual fallback — relaying through another device on
 * the account — is no help when *this* is the device with the SIM.
 *
 * ACTION_SENDTO always works, because the role holder is by definition allowed
 * to send. It costs an app switch and a tap, so it is never the first choice.
 *
 * The important part is that it still syncs: the role holder writes the sent
 * message to content://sms, [SmsProviderObserver] sees the insert, and it comes
 * back in as an ordinary outgoing message that syncs to the server like any
 * other. So the thread stays complete on the Mac, the watches and the other
 * phones, even though this phone never touched the radio itself.
 *
 * Args: address:String, body:String.
 */
class SmsHandoffHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-handoff" }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val address = call.argument<String>("address") ?: ""
        val body = call.argument<String>("body") ?: ""
        if (address.isEmpty()) {
            result.success(false)
            return
        }

        try {
            val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$address")).apply {
                // "sms_body" is the long-standing convention every SMS app reads,
                // including the AOSP-derived OEM ones.
                putExtra("sms_body", body)
                putExtra(Intent.EXTRA_TEXT, body)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            Log.e(Constants.logTag, "sms-handoff failed", e)
            result.success(false)
        }
    }
}
