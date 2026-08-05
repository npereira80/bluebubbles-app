package com.bluebubbles.messaging.wear

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.ContactsContract
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import java.io.ByteArrayOutputStream

/**
 * Sends contact photos to the TN Watch app.
 *
 * A Wear OS watch syncs contact *names* but not photos: querying the watch's own
 * contacts provider returns photo_uri/photo_thumb_uri = NULL for every row. So
 * the phone (which has the Google Contacts photos) pushes them over the Data
 * Layer as Assets, one DataItem per contact keyed by the last 8 digits of the
 * number — the same suffix key the watch matches addresses on.
 */
object WatchAvatarSync {
    private const val TAG = "TnWatchAvatars"
    private const val PATH_PREFIX = "/tnwatch/avatar/"
    private const val MAX_CONTACTS = 400
    private const val TARGET_PX = 96          // avatar is ~40dp on screen
    private const val JPEG_QUALITY = 80

    /** Reads contacts that have a photo and publishes each as a DataItem.
     *  Returns how many were sent. */
    fun pushAll(context: Context): Int {
        val dataClient = Wearable.getDataClient(context)
        var sent = 0
        try {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_URI,
                ),
                null, null, null,
            )?.use { cursor ->
                val seen = HashSet<String>()
                while (cursor.moveToNext() && sent < MAX_CONTACTS) {
                    val number = cursor.getString(0) ?: continue
                    val photoUri = (cursor.getString(1) ?: cursor.getString(2)) ?: continue
                    val digits = number.filter { it.isDigit() }
                    if (digits.length < 6) continue
                    val key = digits.takeLast(8)
                    if (!seen.add(key)) continue

                    val bytes = loadScaled(context, Uri.parse(photoUri)) ?: continue
                    val request = PutDataMapRequest.create(PATH_PREFIX + key).apply {
                        dataMap.putAsset("photo", Asset.createFromBytes(bytes))
                        dataMap.putLong("ts", System.currentTimeMillis())
                    }
                    dataClient.putDataItem(request.asPutDataRequest())
                    sent++
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "pushAll failed: ${e.message}")
        }
        return sent
    }

    /**
     * Pushes a single contact's photo, matched on the last-8-digits [key]. Used
     * as a fallback when a message arrives on the watch from a contact whose
     * photo isn't cached there yet.
     */
    fun pushOne(context: Context, key: String): Boolean {
        if (key.length < 6) return false
        try {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_URI,
                ),
                null, null, null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val number = cursor.getString(0) ?: continue
                    val digits = number.filter { it.isDigit() }
                    if (digits.length < 6 || digits.takeLast(8) != key) continue
                    val photoUri = (cursor.getString(1) ?: cursor.getString(2)) ?: continue
                    val bytes = loadScaled(context, Uri.parse(photoUri)) ?: continue
                    val request = PutDataMapRequest.create(PATH_PREFIX + key).apply {
                        dataMap.putAsset("photo", Asset.createFromBytes(bytes))
                        dataMap.putLong("ts", System.currentTimeMillis())
                    }
                    Wearable.getDataClient(context).putDataItem(request.asPutDataRequest())
                    return true
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "pushOne($key) failed: ${e.message}")
        }
        return false
    }

    /** Decodes a contact photo and re-encodes it small enough to ship cheaply. */
    private fun loadScaled(context: Context, uri: Uri): ByteArray? = try {
        context.contentResolver.openInputStream(uri)?.use { stream ->
            val bitmap = BitmapFactory.decodeStream(stream) ?: return null
            val longest = maxOf(bitmap.width, bitmap.height)
            val scaled = if (longest > TARGET_PX) {
                val factor = TARGET_PX.toFloat() / longest
                Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * factor).toInt().coerceAtLeast(1),
                    (bitmap.height * factor).toInt().coerceAtLeast(1),
                    true,
                )
            } else {
                bitmap
            }
            ByteArrayOutputStream().use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
                out.toByteArray()
            }
        }
    } catch (e: Exception) {
        null
    }
}
