package com.bluebubbles.messaging.services.sms

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.R
import com.google.android.mms.pdu_alt.CharacterSets
import com.google.android.mms.pdu_alt.EncodedStringValue
import com.google.android.mms.pdu_alt.PduBody
import com.google.android.mms.pdu_alt.PduComposer
import com.google.android.mms.pdu_alt.PduPart
import com.google.android.mms.pdu_alt.SendReq
import java.io.File

/**
 * Sends an MMS (text + media) via the platform: builds an M-Send.req PDU (with
 * klinker41's AOSP pdu_alt classes), hands it to SmsManager.sendMultimediaMessage
 * through a FileProvider content URI, and attaches a sent-status PendingIntent so
 * success/failure is actually reported (see [MmsSentReceiver]). Also persists the
 * message to the MMS Sent box so it shows locally + syncs.
 *
 * Note: MMS transmits over the cellular data (MMS APN), so mobile data must be on.
 */
object MmsSender {

    data class Part(val bytes: ByteArray, val mime: String, val name: String?)

    fun send(context: Context, addresses: List<String>, text: String, media: List<Part>, messageId: String? = null) {
        val subId = SubscriptionManager.getDefaultSmsSubscriptionId()
        val sms = if (subId >= 0) SmsManager.getSmsManagerForSubscriptionId(subId)
                  else context.getSystemService(SmsManager::class.java)
        if (sms == null) { Log.e(Constants.logTag, "MmsSender: no SmsManager"); throw IllegalStateException("no SmsManager") }

        // Build the send-request PDU.
        val req = SendReq()
        for (a in addresses) req.addTo(EncodedStringValue(a))
        req.date = System.currentTimeMillis() / 1000
        val body = PduBody()
        if (text.isNotEmpty()) {
            val p = PduPart()
            p.contentType = "text/plain".toByteArray()
            p.name = "text".toByteArray()
            p.charset = CharacterSets.UTF_8
            p.data = text.toByteArray()
            body.addPart(p)
        }
        media.forEachIndexed { i, m ->
            // MMS has tight carrier size limits (~300KB–1MB); downscale/compress
            // images so the send isn't rejected. Non-images are sent as-is.
            val (data, mime) = compressImage(m.bytes, m.mime)
            var base = (m.name ?: "attachment$i").replace("[^A-Za-z0-9._-]".toRegex(), "_")
            if (mime == "image/jpeg" && !base.endsWith(".jpg", true) && !base.endsWith(".jpeg", true)) {
                base = base.substringBeforeLast('.', base) + ".jpg"
            }
            val p = PduPart()
            p.contentType = mime.toByteArray()
            p.name = base.toByteArray()
            p.contentLocation = base.toByteArray()
            p.contentId = "<$base>".toByteArray()
            p.data = data
            body.addPart(p)
            Log.i(Constants.logTag, "MmsSender: part $base ${m.bytes.size}B -> ${data.size}B ($mime)")
        }
        req.body = body

        val pduBytes = PduComposer(context, req).make()
        if (pduBytes == null) { Log.e(Constants.logTag, "MmsSender: PduComposer returned null"); throw IllegalStateException("compose failed") }

        // Write the PDU where the telephony stack can read it.
        val dir = File(context.cacheDir, "mms").apply { mkdirs() }
        val file = File(dir, "send_${System.currentTimeMillis()}.pdu").apply { writeBytes(pduBytes) }
        val contentUri = FileProvider.getUriForFile(context, context.getString(R.string.file_provider), file)
        context.grantUriPermission("com.android.phone", contentUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

        // The result receiver persists to the Sent box only on success, so a
        // failed send never shows up (or syncs to the Mac) as "sent".
        val sentIntent = Intent(context, MmsSentReceiver::class.java).apply {
            setPackage(context.packageName)
            putExtra(MmsSentReceiver.EXTRA_FILE_PATH, file.absolutePath)
            putExtra(MmsSentReceiver.EXTRA_SUB_ID, subId)
            if (messageId != null) putExtra(MmsSentReceiver.EXTRA_MESSAGE_ID, messageId)
            data = contentUri
        }
        val sentPI = PendingIntent.getBroadcast(
            context, file.hashCode(), sentIntent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        Log.i(Constants.logTag, "MmsSender: sending MMS to ${addresses.joinToString()} " +
            "(${media.size} media, ${pduBytes.size} bytes PDU, subId=$subId)")
        sms.sendMultimediaMessage(context, contentUri, null, null, sentPI)
    }

    /** Downscale + JPEG-compress an image under a carrier-friendly size budget. */
    private fun compressImage(bytes: ByteArray, mime: String): Pair<ByteArray, String> {
        if (!mime.startsWith("image/")) return bytes to mime
        val maxBytes = 600 * 1024   // ~600KB target
        val bitmap = try { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) } catch (_: Exception) { null }
            ?: return bytes to mime
        val maxDim = 1280
        val longest = maxOf(bitmap.width, bitmap.height)
        val scaled = if (longest > maxDim) {
            val f = maxDim.toFloat() / longest
            Bitmap.createScaledBitmap(bitmap, (bitmap.width * f).toInt().coerceAtLeast(1),
                (bitmap.height * f).toInt().coerceAtLeast(1), true)
        } else bitmap
        var quality = 85
        var out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
        while (out.size() > maxBytes && quality > 30) {
            quality -= 15
            out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
        }
        return out.toByteArray() to "image/jpeg"
    }
}
