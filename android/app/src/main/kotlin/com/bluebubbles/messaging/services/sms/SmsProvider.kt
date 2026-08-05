package com.bluebubbles.messaging.services.sms

import android.content.ContentValues
import android.content.Context
import android.provider.Telephony

/**
 * Read/write access to the system SMS (Telephony) provider. Writes require the
 * app to be the **default SMS app** — that is the whole point of the TN
 * Messages fork. The Dart layer owns sync-to-server and the ObjectBox model;
 * this object only touches the OS SMS store.
 *
 * Message maps use these keys (shared contract with the Dart SmsService):
 *   providerId:Long, address:String, body:String, date:Long(ms),
 *   read:Boolean, isFromMe:Boolean, type:"sms"
 */
object SmsProvider {

    private val SMS_URI = Telephony.Sms.CONTENT_URI

    fun count(context: Context): Int {
        context.contentResolver.query(SMS_URI, arrayOf(Telephony.Sms._ID), null, null, null)
            ?.use { return it.count }
        return 0
    }

    /** Read SMS with DATE > [since] (ms), oldest first, as message maps. */
    fun readSince(context: Context, since: Long): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val cols = arrayOf(
            Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
            Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ,
        )
        context.contentResolver.query(
            SMS_URI, cols, "${Telephony.Sms.DATE} > ?", arrayOf(since.toString()),
            "${Telephony.Sms.DATE} ASC",
        )?.use { c ->
            val idI = c.getColumnIndexOrThrow(Telephony.Sms._ID)
            val adI = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val boI = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val daI = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val tyI = c.getColumnIndexOrThrow(Telephony.Sms.TYPE)
            val reI = c.getColumnIndexOrThrow(Telephony.Sms.READ)
            while (c.moveToNext()) {
                val type = c.getInt(tyI)
                val fromMe = type == Telephony.Sms.MESSAGE_TYPE_SENT
                val inbox = type == Telephony.Sms.MESSAGE_TYPE_INBOX
                if (!fromMe && !inbox) continue
                out.add(
                    mapOf(
                        "providerId" to c.getLong(idI),
                        "address" to (c.getString(adI) ?: ""),
                        "body" to (c.getString(boI) ?: ""),
                        "date" to c.getLong(daI),
                        "read" to (c.getInt(reI) == 1),
                        "isFromMe" to fromMe,
                        "type" to "sms",
                    )
                )
            }
        }
        return out
    }

    /** Persist an incoming SMS (default-app responsibility). Returns row _id. */
    fun insertInbox(context: Context, address: String, body: String, dateMs: Long): Long {
        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, dateMs)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
        }
        val uri = context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values)
        return uri?.lastPathSegment?.toLongOrNull() ?: -1L
    }

    /** Record an outgoing SMS in the Sent box (so it shows as sent history). */
    fun insertSent(context: Context, address: String, body: String, dateMs: Long): Long {
        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, address)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, dateMs)
            put(Telephony.Sms.READ, 1)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT)
        }
        val uri = context.contentResolver.insert(Telephony.Sms.Sent.CONTENT_URI, values)
        return uri?.lastPathSegment?.toLongOrNull() ?: -1L
    }

    /** Mark all inbox messages from [address] as read. */
    fun markThreadRead(context: Context, address: String): Int {
        val values = ContentValues().apply { put(Telephony.Sms.READ, 1) }
        return context.contentResolver.update(
            SMS_URI, values,
            "${Telephony.Sms.ADDRESS} = ? AND ${Telephony.Sms.READ} = 0",
            arrayOf(address),
        )
    }

    /** Hard-delete provider rows by _id. Returns number deleted. */
    fun deleteByIds(context: Context, ids: List<Long>): Int {
        var deleted = 0
        for (id in ids) {
            deleted += context.contentResolver.delete(SMS_URI, "${Telephony.Sms._ID} = ?", arrayOf(id.toString()))
        }
        return deleted
    }

    /**
     * Delete provider rows matching a specific date+body. Used when the user
     * deletes a message in the app UI: without this the row stays in the system
     * SMS store and the next backfill re-imports (resurrects) it. date is unique
     * enough per message that matching date+body is safe. Returns count deleted.
     */
    fun deleteMatching(context: Context, dateMs: Long, body: String): Int {
        return context.contentResolver.delete(
            SMS_URI,
            "${Telephony.Sms.DATE} = ? AND ${Telephony.Sms.BODY} = ?",
            arrayOf(dateMs.toString(), body),
        )
    }
}
