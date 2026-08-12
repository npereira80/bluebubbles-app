package com.bluebubbles.messaging.services.sms

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method-channel handlers for the SMS engine (TN Messages fork). Registered in
 * MethodCallHandler.dispatchHandler. Method names live in each companion `tag`.
 * The Dart SmsService is the only caller.
 */

/** Whether this app is currently Android's default SMS app. */
class SmsIsDefaultHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-is-default" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val isDefault = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // RoleManager is the authoritative check on API 29+.
            context.getSystemService(RoleManager::class.java)?.isRoleHeld(RoleManager.ROLE_SMS) == true
        } else {
            Telephony.Sms.getDefaultSmsPackage(context) == context.packageName
        }
        result.success(isDefault)
    }
}

/**
 * Which SMS/MMS runtime permissions are actually granted.
 *
 * Holding the SMS role normally grants these along with it, but not always: on
 * some OEM builds (and when the role is set from Settings rather than through our
 * prompt) the role sticks while the permission group stays denied. The app then
 * looks correctly configured and silently receives nothing, because the system
 * drops SMS_DELIVER with a Permission Denial. Surfacing the real grant state is
 * the difference between a five-minute fix and a long hunt.
 *
 * Returns a name -> granted map, plus `all` for the summary line.
 */
class SmsPermissionsHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "sms-permissions"

        /** Everything the default SMS app needs to receive and send SMS + MMS. */
        private val required = listOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS,
            Manifest.permission.RECEIVE_MMS,
            Manifest.permission.RECEIVE_WAP_PUSH,
        )
    }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val granted = required.associateWith {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        val out = mutableMapOf<String, Any>()
        // Short names: the fully qualified ones are unreadable in a settings row.
        granted.forEach { (permission, ok) -> out[permission.substringAfterLast('.')] = ok }
        out["all"] = granted.values.all { it }
        out["missing"] = granted.filterValues { !it }.keys.map { it.substringAfterLast('.') }
        result.success(out)
    }
}

/**
 * Ask for any missing SMS/MMS permission. Falls back to the app's settings page,
 * which is where the user ends up anyway once a permission has been permanently
 * denied and the system stops showing the dialog.
 */
class SmsRequestPermissionsHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-request-permissions" }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val wanted = arrayOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS,
            Manifest.permission.RECEIVE_MMS,
            Manifest.permission.RECEIVE_WAP_PUSH,
        )
        val activity = context as? Activity
        if (activity != null) {
            ActivityCompat.requestPermissions(activity, wanted, 4310)
            result.success(true)
            return
        }
        runCatching {
            context.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
        result.success(false)
    }
}

/** Prompt the user to make this app the default SMS app. */
class SmsRequestDefaultHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-request-default" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        try {
            val intent: Intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val rm = context.getSystemService(RoleManager::class.java)
                rm!!.createRequestRoleIntent(RoleManager.ROLE_SMS)
            } else {
                @Suppress("DEPRECATION")
                Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT)
                    .putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, context.packageName)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("sms_default_request_failed", e.message, null)
        }
    }
}

/** Read SMS history since a timestamp (ms). Arg: since:Long. */
class SmsQueryHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-query" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val since = (call.argument<Any>("since") as? Number)?.toLong() ?: 0L
        result.success(SmsProvider.readSince(context, since))
    }
}

class SmsCountHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-count" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        result.success(SmsProvider.count(context))
    }
}

/** Send an SMS. Args: address:String, body:String, messageId:String. */
class SmsSendHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-send" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val address = call.argument<String>("address")
        val body = call.argument<String>("body")
        val messageId = call.argument<String>("messageId") ?: address.hashCode().toString()
        if (address.isNullOrEmpty() || body == null) {
            result.error("sms_send_bad_args", "address and body are required", null); return
        }
        SmsSender.send(context, messageId, address, body)
        result.success(mapOf("messageId" to messageId))
    }
}

/** Mark a thread read in the provider. Arg: address:String. */
class SmsMarkReadHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-mark-read" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val address = call.argument<String>("address")
        if (address.isNullOrEmpty()) { result.error("sms_mark_read_bad_args", "address required", null); return }
        result.success(SmsProvider.markThreadRead(context, address))
    }
}

/** Delete provider rows. Arg: ids:List<Number>. */
class SmsDeleteHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-delete" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val ids = call.argument<List<Number>>("ids")?.map { it.toLong() } ?: emptyList()
        result.success(SmsProvider.deleteByIds(context, ids))
    }
}

/** Delete provider rows matching date+body (used when a message is deleted in
 *  the UI, so backfill doesn't resurrect it). Args: date:Number, body:String. */
class SmsDeleteMatchHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-delete-match" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val date = call.argument<Number>("date")?.toLong() ?: 0L
        val body = call.argument<String>("body") ?: ""
        // Try both stores: an MMS left in the provider gets re-imported by the
        // next backfill exactly like an SMS would.
        val removed = SmsProvider.deleteMatching(context, date, body) +
            MmsProvider.deleteMatching(context, date)
        result.success(removed)
    }
}

/**
 * Delete an entire conversation from the system store (SMS + MMS), so the thread
 * disappears from other SMS apps and our own backfill can't resurrect it.
 * Arg: address:String.
 */
class SmsDeleteThreadHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-delete-thread" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val address = call.argument<String>("address") ?: ""
        result.success(SmsProvider.deleteThread(context, address))
    }
}

/** SIM presence + key. */
class SmsSimInfoHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-sim-info" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        result.success(SimInfo.read(context))
    }
}
