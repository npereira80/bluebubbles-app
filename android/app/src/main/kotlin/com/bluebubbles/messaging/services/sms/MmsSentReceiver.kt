package com.bluebubbles.messaging.services.sms

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.google.android.mms.pdu_alt.PduParser
import com.google.android.mms.pdu_alt.PduPersister
import java.io.File

/**
 * Result of a platform MMS send (fired by SmsManager.sendMultimediaMessage via a
 * PendingIntent). Logs OK/FAILED with the code. On success it persists the sent
 * PDU to the MMS Sent box and nudges Dart to backfill/sync it, so a message only
 * shows as "sent" (locally and on the Mac) once it actually went out.
 */
class MmsSentReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_FILE_PATH = "filePath"
        const val EXTRA_SUB_ID = "subId"
        const val EXTRA_MESSAGE_ID = "messageId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val code = resultCode
        val ok = code == Activity.RESULT_OK
        val path = intent.getStringExtra(EXTRA_FILE_PATH)
        val subId = intent.getIntExtra(EXTRA_SUB_ID, -1)
        val messageId = intent.getStringExtra(EXTRA_MESSAGE_ID)
        Log.i(Constants.logTag, "MmsSender: send result=${if (ok) "OK" else "FAILED(code=$code)"}")

        if (ok && path != null) {
            try {
                val pdu = PduParser(File(path).readBytes(), true).parse()
                if (pdu != null) {
                    PduPersister.getPduPersister(context)
                        .persist(pdu, Telephony.Mms.Sent.CONTENT_URI, true, true, null, subId)
                    // Surface + sync the just-sent MMS (backfillMms reads the Sent box).
                    runCatching { MethodCallHandler.invokeMethod("mms-received", mapOf("providerId" to -1L)) }
                }
            } catch (e: Exception) {
                Log.e(Constants.logTag, "MmsSender: persisting sent MMS failed", e)
            }
        }

        // Reconcile the optimistic bubble: reuse the SMS sent-status channel so
        // Dart marks the message delivered (ok) or failed. Without this a failed
        // MMS send keeps showing as "Delivered".
        if (messageId != null) {
            val status = if (ok) "sent" else "failed"
            runCatching {
                MethodCallHandler.invokeMethod("sms-sent-status", mapOf("messageId" to messageId, "status" to status))
            }
        }
        path?.let { runCatching { File(it).delete() } }
    }
}
