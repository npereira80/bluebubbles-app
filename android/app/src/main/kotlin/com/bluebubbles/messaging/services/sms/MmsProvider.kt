package com.bluebubbles.messaging.services.sms

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.Telephony
import android.util.Log
import com.bluebubbles.messaging.Constants
import java.io.ByteArrayOutputStream

/**
 * Read access to the system MMS (Telephony) provider for the TN Messages fork.
 * Mirrors [SmsProvider] but for MMS: a message has a text body plus zero or more
 * media parts (image/video/audio/vCard/…). Writes to the MMS store are done by
 * the download/send transactions (klinker41); this object only reads what's
 * already persisted so the Dart layer can sync it to the server.
 *
 * Message maps (shared contract with Dart SmsService):
 *   providerId:Long, address:String, body:String, date:Long(ms),
 *   read:Boolean, isFromMe:Boolean, type:"mms",
 *   parts: List<{ partId:Long, contentType:String, name:String? }>  // media only
 */
object MmsProvider {

    private val MMS_URI: Uri = Telephony.Mms.CONTENT_URI                 // content://mms
    private val PART_URI: Uri = Uri.parse("content://mms/part")

    // PDU address types (com.google.android.mms.pdu.PduHeaders).
    private const val ADDR_FROM = 137
    private const val ADDR_TO = 151
    private const val INSERT_ADDRESS_TOKEN = "insert-address-token"      // placeholder for "me"

    /** Read MMS with DATE (seconds) newer than [sinceMs], oldest first. */
    fun readSince(context: Context, sinceMs: Long): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val sinceSec = sinceMs / 1000
        val cols = arrayOf(
            Telephony.Mms._ID, Telephony.Mms.DATE, Telephony.Mms.MESSAGE_BOX, Telephony.Mms.READ,
        )
        context.contentResolver.query(
            MMS_URI, cols, "${Telephony.Mms.DATE} > ?", arrayOf(sinceSec.toString()),
            "${Telephony.Mms.DATE} ASC",
        )?.use { c ->
            val idI = c.getColumnIndexOrThrow(Telephony.Mms._ID)
            val daI = c.getColumnIndexOrThrow(Telephony.Mms.DATE)
            val boxI = c.getColumnIndexOrThrow(Telephony.Mms.MESSAGE_BOX)
            val reI = c.getColumnIndexOrThrow(Telephony.Mms.READ)
            while (c.moveToNext()) {
                val id = c.getLong(idI)
                val box = c.getInt(boxI)
                val fromMe = box == Telephony.Mms.MESSAGE_BOX_SENT
                val inbox = box == Telephony.Mms.MESSAGE_BOX_INBOX
                if (!fromMe && !inbox) continue      // skip drafts/outbox

                val (body, mediaParts) = readParts(context, id)
                val address = readAddress(context, id, fromMe)
                if (address.isEmpty()) continue

                out.add(
                    mapOf(
                        "providerId" to id,
                        "address" to address,
                        "body" to body,
                        "date" to c.getLong(daI) * 1000L,   // MMS DATE is seconds
                        "read" to (c.getInt(reI) == 1),
                        "isFromMe" to fromMe,
                        "type" to "mms",
                        "parts" to mediaParts,
                    )
                )
            }
        }
        return out
    }

    /** Returns the concatenated text body and the list of media-part descriptors. */
    private fun readParts(context: Context, mmsId: Long): Pair<String, List<Map<String, Any?>>> {
        val text = StringBuilder()
        val media = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            PART_URI, arrayOf("_id", Telephony.Mms.Part.CONTENT_TYPE, Telephony.Mms.Part.NAME,
                Telephony.Mms.Part.FILENAME, Telephony.Mms.Part.TEXT),
            "${Telephony.Mms.Part.MSG_ID} = ?", arrayOf(mmsId.toString()), null,
        )?.use { c ->
            val idI = c.getColumnIndexOrThrow("_id")
            val ctI = c.getColumnIndexOrThrow(Telephony.Mms.Part.CONTENT_TYPE)
            val nmI = c.getColumnIndexOrThrow(Telephony.Mms.Part.NAME)
            val fnI = c.getColumnIndexOrThrow(Telephony.Mms.Part.FILENAME)
            val txI = c.getColumnIndexOrThrow(Telephony.Mms.Part.TEXT)
            while (c.moveToNext()) {
                val ct = (c.getString(ctI) ?: "").lowercase()
                when {
                    ct == "application/smil" -> { /* layout only, skip */ }
                    ct.startsWith("text/") -> {
                        val t = c.getString(txI)
                        if (!t.isNullOrEmpty()) text.append(t)
                    }
                    else -> media.add(
                        mapOf(
                            "partId" to c.getLong(idI),
                            "contentType" to ct,
                            "name" to (c.getString(nmI) ?: c.getString(fnI)),
                        )
                    )
                }
            }
        }
        return text.toString() to media
    }

    /** The other party's address (sender for inbox, first recipient for sent). */
    private fun readAddress(context: Context, mmsId: Long, fromMe: Boolean): String {
        val wanted = if (fromMe) ADDR_TO else ADDR_FROM
        val uri = Uri.parse("content://mms/$mmsId/addr")
        context.contentResolver.query(
            uri, arrayOf(Telephony.Mms.Addr.ADDRESS, Telephony.Mms.Addr.TYPE),
            "${Telephony.Mms.Addr.TYPE} = ?", arrayOf(wanted.toString()), null,
        )?.use { c ->
            val adI = c.getColumnIndexOrThrow(Telephony.Mms.Addr.ADDRESS)
            while (c.moveToNext()) {
                val a = c.getString(adI) ?: continue
                if (a.isNotEmpty() && a != INSERT_ADDRESS_TOKEN) return a
            }
        }
        return ""
    }

    /** Raw bytes of a single MMS part, read from content://mms/part/<partId>. */
    fun partBytes(context: Context, partId: Long): ByteArray? {
        val uri = ContentUris.withAppendedId(PART_URI, partId)
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val out = ByteArrayOutputStream()
                input.copyTo(out)
                out.toByteArray()
            }
        } catch (e: Exception) {
            Log.e(Constants.logTag, "MmsProvider: failed reading part $partId", e)
            null
        }
    }

    /** Delete an MMS by provider _id (used when a message is deleted in the UI). */
    fun deleteById(context: Context, mmsId: Long): Int {
        return context.contentResolver.delete(ContentUris.withAppendedId(MMS_URI, mmsId), null, null)
    }
}
