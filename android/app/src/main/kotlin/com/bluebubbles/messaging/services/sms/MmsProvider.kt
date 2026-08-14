package com.bluebubbles.messaging.services.sms

import android.content.ContentUris
import android.content.ContentValues
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

    /**
     * Write an MMS restored from our sync server into the system store: the
     * message row, its address rows, and one part per attachment (plus a text
     * part when there's a caption).
     *
     * Unlike an SMS this is several inserts — the provider models an MMS as a
     * PDU with children — and the parts have to be written through the part
     * URI's stream, not as a byte column.
     *
     * Returns false if an MMS with the same timestamp is already present, so a
     * re-run is safe.
     */
    fun insertRestored(
        context: Context,
        address: String,
        body: String,
        dateMs: Long,
        isFromMe: Boolean,
        read: Boolean,
        parts: List<Map<String, Any?>>,
    ): Boolean {
        val dateSec = dateMs / 1000
        if (exists(context, dateSec)) return false

        val threadId = try {
            Telephony.Threads.getOrCreateThreadId(context, address)
        } catch (e: Exception) {
            Log.w(Constants.logTag, "MMS restore: no thread id for the address: ${e.message}")
            return false
        }

        val values = ContentValues().apply {
            put(Telephony.Mms.THREAD_ID, threadId)
            put(Telephony.Mms.DATE, dateSec)                 // the MMS table is in seconds
            put(Telephony.Mms.READ, if (read || isFromMe) 1 else 0)
            put(Telephony.Mms.MESSAGE_BOX, if (isFromMe) Telephony.Mms.MESSAGE_BOX_SENT else Telephony.Mms.MESSAGE_BOX_INBOX)
            put(Telephony.Mms.MESSAGE_TYPE, 132)             // M_RETRIEVE_CONF
            put(Telephony.Mms.MMS_VERSION, 18)
            put(Telephony.Mms.CONTENT_TYPE, "application/vnd.wap.multipart.related")
            put(Telephony.Mms.SEEN, 1)
        }
        val messageUri = context.contentResolver.insert(MMS_URI, values) ?: return false
        val mmsId = messageUri.lastPathSegment?.toLongOrNull() ?: return false

        // Addresses: who it's from and who it's to. "Me" is written as the
        // provider's placeholder token rather than our own number, which we may
        // not even know.
        insertAddress(context, mmsId, if (isFromMe) INSERT_ADDRESS_TOKEN else address, ADDR_FROM)
        insertAddress(context, mmsId, if (isFromMe) address else INSERT_ADDRESS_TOKEN, ADDR_TO)

        if (body.isNotEmpty()) insertTextPart(context, mmsId, body)
        var index = 0
        for (part in parts) {
            val bytes = part["bytes"] as? ByteArray ?: continue
            val mime = part["mime"] as? String ?: "application/octet-stream"
            val name = part["name"] as? String ?: "part_$index"
            insertMediaPart(context, mmsId, mime, name, bytes, index)
            index++
        }
        return true
    }

    private fun exists(context: Context, dateSec: Long): Boolean {
        return context.contentResolver.query(
            MMS_URI,
            arrayOf(Telephony.Mms._ID),
            "${Telephony.Mms.DATE} = ?",
            arrayOf(dateSec.toString()),
            null,
        )?.use { it.moveToFirst() } ?: false
    }

    private fun insertAddress(context: Context, mmsId: Long, address: String, type: Int) {
        val values = ContentValues().apply {
            put("address", address)
            put("type", type)
            put("charset", 106)                              // UTF-8
        }
        runCatching {
            context.contentResolver.insert(Uri.parse("content://mms/$mmsId/addr"), values)
        }.onFailure { Log.w(Constants.logTag, "MMS restore: address row failed: ${it.message}") }
    }

    private fun insertTextPart(context: Context, mmsId: Long, text: String) {
        val values = ContentValues().apply {
            put("mid", mmsId)
            put("seq", 0)
            put("ct", "text/plain")
            put("chset", 106)
            put("name", "text.txt")
            put("text", text)
        }
        runCatching { context.contentResolver.insert(PART_URI, values) }
            .onFailure { Log.w(Constants.logTag, "MMS restore: text part failed: ${it.message}") }
    }

    private fun insertMediaPart(
        context: Context,
        mmsId: Long,
        mime: String,
        name: String,
        bytes: ByteArray,
        index: Int,
    ) {
        val values = ContentValues().apply {
            put("mid", mmsId)
            put("seq", index)
            put("ct", mime)
            put("name", name)
            put("cid", "<$name>")
            put("cl", name)
        }
        val uri = runCatching { context.contentResolver.insert(PART_URI, values) }.getOrNull()
        if (uri == null) {
            Log.w(Constants.logTag, "MMS restore: could not create part row")
            return
        }
        // Bytes go through the stream; there's no column to write them to.
        runCatching {
            context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
        }.onFailure { Log.w(Constants.logTag, "MMS restore: writing part bytes failed: ${it.message}") }
    }

    /** Delete an MMS by provider _id (used when a message is deleted in the UI). */
    fun deleteById(context: Context, mmsId: Long): Int {
        return context.contentResolver.delete(ContentUris.withAppendedId(MMS_URI, mmsId), null, null)
    }

    /**
     * Delete the MMS matching this timestamp. Counterpart to the SMS date+body
     * match: without it a deleted MMS stayed in the system store and the next
     * backfill re-imported it. Note MMS dates are stored in SECONDS.
     */
    fun deleteMatching(context: Context, dateMs: Long): Int {
        if (dateMs <= 0) return 0
        val seconds = dateMs / 1000
        return runCatching {
            context.contentResolver.delete(MMS_URI, "date = ?", arrayOf(seconds.toString()))
        }.getOrDefault(0)
    }
}
