package com.bluebubbles.messaging.services.sms

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.FileProvider
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.R
import com.google.android.mms.pdu_alt.GenericPdu
import com.google.android.mms.pdu_alt.NotificationInd
import com.google.android.mms.pdu_alt.PduParser
import java.io.File

/**
 * Default-app MMS delivery. On the WAP push we parse the notification to find
 * the MMSC content location, then ask the telephony stack to download the full
 * message into a temp file we own (shared via FileProvider). The retrieved PDU
 * is handled by [MmsDownloadedReceiver].
 *
 * The download itself is carrier/APN-specific — watch logcat (tag "$Constants")
 * for "MMS:" lines if a message doesn't arrive.
 */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pushData = intent.getByteArrayExtra("data")
        if (pushData == null) {
            Log.w(Constants.logTag, "MMS: WAP_PUSH_DELIVER with no data")
            return
        }
        val pdu: GenericPdu? = try {
            PduParser(pushData, true).parse()
        } catch (e: Exception) {
            Log.e(Constants.logTag, "MMS: failed to parse WAP push", e); null
        }
        if (pdu !is NotificationInd) {
            Log.w(Constants.logTag, "MMS: push not a NotificationInd (type=${pdu?.messageType})")
            return
        }
        val location = pdu.contentLocation?.let { String(it) }
        if (location.isNullOrEmpty()) {
            Log.w(Constants.logTag, "MMS: notification carried no content location")
            return
        }
        Log.i(Constants.logTag, "MMS: incoming notification, downloading")

        // A file the telephony stack writes the retrieved PDU into.
        val dir = File(context.cacheDir, "mms").apply { mkdirs() }
        val file = File(dir, "download_${System.currentTimeMillis()}.pdu").apply {
            if (exists()) delete(); createNewFile()
        }
        val contentUri = FileProvider.getUriForFile(context, context.getString(R.string.file_provider), file)

        val downloaded = Intent(context, MmsDownloadedReceiver::class.java).apply {
            setPackage(context.packageName)
            putExtra(MmsDownloadedReceiver.EXTRA_FILE_PATH, file.absolutePath)
            data = contentUri
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        val pi = PendingIntent.getBroadcast(
            context, location.hashCode(), downloaded,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Let the carrier download service read/write our transfer file.
        context.grantUriPermission("com.android.phone", contentUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

        val sms = context.getSystemService(SmsManager::class.java)
        if (sms == null) { Log.e(Constants.logTag, "MMS: no SmsManager"); return }
        try {
            sms.downloadMultimediaMessage(context, location, contentUri, null, pi)
        } catch (e: Exception) {
            Log.e(Constants.logTag, "MMS: downloadMultimediaMessage threw", e)
        }
    }
}
