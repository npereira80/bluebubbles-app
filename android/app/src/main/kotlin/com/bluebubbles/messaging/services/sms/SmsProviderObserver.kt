package com.bluebubbles.messaging.services.sms

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Watches the system SMS/MMS store for changes.
 *
 * Only the default SMS app receives SMS_DELIVER, and some OEM ROMs will not let
 * a sideloaded app hold that role — vivo's China build reassigns it back to its
 * own Messages app within seconds, protects that app from `pm disable-user` and
 * `pm uninstall --user 0`, and shows a system dialog calling the reassignment a
 * security measure. On such a device the app can still *read* every message,
 * because whichever app does hold the role is obliged to write it to
 * content://sms.
 *
 * So this is the fallback path: observe the provider, and let Dart run its normal
 * backfill when something appears. A ContentObserver fires as soon as the row is
 * inserted, which is why it's preferred over polling — the poll on the Dart side
 * only exists to cover the case where a ROM suppresses the notification too.
 *
 * Registered for the life of the process, and harmless when the app *does* hold
 * the role: the backfill it triggers is idempotent, and skips rows already
 * imported.
 */
object SmsProviderObserver {

    /** Dart method invoked when the store changes. */
    private const val CHANGED = "sms-provider-changed"

    private var observer: ContentObserver? = null

    fun start(context: Context) {
        if (observer != null) return

        val obs = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                // Deliberately no payload. The observer says "something changed",
                // not what — reading the row here would duplicate the cursor
                // handling, the MMS part assembly and the dedupe that the Dart
                // backfill already does correctly.
                // invokeMethod takes a non-null Map<String, Any>; the uri is only
                // ever informational, since Dart re-reads from its own cursor.
                runCatching { MethodCallHandler.invokeMethod(CHANGED, mapOf("uri" to (uri?.toString() ?: ""))) }
                    .onFailure { Log.d(Constants.logTag, "Provider change: Dart engine not up") }
            }
        }

        try {
            // notifyForDescendants = true: an MMS lands as a row in content://mms
            // plus rows under content://mms/part, and the useful notification is
            // often on the descendant rather than the root.
            context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, obs)
            context.contentResolver.registerContentObserver(Telephony.Mms.CONTENT_URI, true, obs)
            observer = obs
        } catch (e: Exception) {
            // Without READ_SMS this throws. Not fatal: the app either holds the
            // role (and gets broadcasts instead) or has nothing to read yet.
            Log.w(Constants.logTag, "Could not observe the SMS provider", e)
        }
    }

    fun stop(context: Context) {
        val obs = observer ?: return
        runCatching { context.contentResolver.unregisterContentObserver(obs) }
        observer = null
    }
}

/** Starts the provider observer. Idempotent. */
class SmsObserveProviderHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-observe-provider" }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        SmsProviderObserver.start(context)
        result.success(true)
    }
}

/**
 * Notify for a message that was read out of the provider rather than received.
 *
 * Needed only in observer mode. Without the SMS role there is no SMS_DELIVER and
 * so no [SmsDeliverReceiver] to post the notification, which would leave the OEM
 * app as the only thing alerting — and tapping that opens the OEM app. Reuses
 * [SmsNotifications] so the channel, grouping and tap target match the normal
 * path exactly.
 *
 * Args: address:String, body:String.
 */
class SmsNotifyHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "sms-notify" }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val address = call.argument<String>("address") ?: ""
        val body = call.argument<String>("body") ?: ""
        runCatching { SmsNotifications.notify(context, address, body) }
            .onFailure { Log.e(Constants.logTag, "sms-notify failed", it) }
        result.success(true)
    }
}
