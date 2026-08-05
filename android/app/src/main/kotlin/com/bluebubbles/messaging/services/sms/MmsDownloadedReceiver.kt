package com.bluebubbles.messaging.services.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.google.android.mms.pdu_alt.PduParser
import com.google.android.mms.pdu_alt.PduPersister
import com.google.android.mms.pdu_alt.RetrieveConf
import java.io.File

/**
 * Fires when the telephony stack finishes retrieving an MMS (kicked off by
 * [MmsDeliverReceiver]). Parses the retrieve-conf PDU, persists it to the system
 * MMS inbox (message + parts + addresses), then tells Dart to sync it up. Must
 * be declared in the manifest since the framework targets it via PendingIntent.
 */
class MmsDownloadedReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_FILE_PATH = "filePath"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val result = resultCode
        val filePath = intent.getStringExtra(EXTRA_FILE_PATH)
        Log.i(Constants.logTag, "MMS: download finished result=$result")
        if (result != Activity.RESULT_OK || filePath == null) {
            Log.w(Constants.logTag, "MMS: download failed (result=$result)")
            filePath?.let { runCatching { File(it).delete() } }
            return
        }
        val bytes = try {
            File(filePath).readBytes()
        } catch (e: Exception) {
            Log.e(Constants.logTag, "MMS: cannot read downloaded pdu", e); return
        }
        val pdu = try {
            PduParser(bytes, true).parse()
        } catch (e: Exception) {
            Log.e(Constants.logTag, "MMS: parse retrieve-conf failed", e); null
        }
        runCatching { File(filePath).delete() }
        if (pdu !is RetrieveConf) {
            Log.w(Constants.logTag, "MMS: downloaded pdu is not a RetrieveConf (type=${pdu?.messageType})")
            return
        }

        // Persist to the system MMS store (message + parts + addresses). true,true
        // = create a thread id and honour group-MMS threading.
        val subId = SubscriptionManager.getDefaultSmsSubscriptionId()
        val uri: Uri? = try {
            PduPersister.getPduPersister(context)
                .persist(pdu, Telephony.Mms.Inbox.CONTENT_URI, true, true, null, subId)
        } catch (e: Exception) {
            Log.e(Constants.logTag, "MMS: persist to provider failed", e); null
        }
        if (uri == null) return
        val mmsId = uri.lastPathSegment?.toLongOrNull() ?: -1L
        val from = pdu.from?.string ?: ""
        Log.i(Constants.logTag, "MMS: persisted id=$mmsId from=$from")

        // Native notification (fires even if the Flutter engine is dead).
        SmsNotifications.notify(context, from, "📷 Attachment")

        // Nudge Dart to sync it to the server (best-effort; periodic sync is the
        // safety net if the engine isn't alive right now).
        runCatching {
            MethodCallHandler.invokeMethod(
                "mms-received", mapOf("providerId" to mmsId, "address" to from),
            )
        }
    }
}
