package com.bluebubbles.messaging.services.sms

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.ContactsContract
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.bluebubbles.messaging.Constants

/**
 * Posts a system notification for an incoming SMS directly from the native
 * SMS_DELIVER receiver, so notifications fire even when the Flutter engine
 * isn't alive (app killed / background). Independent of the BlueBubbles
 * iMessage notification path.
 */
object SmsNotifications {
    private const val CHANNEL_ID = "sms_incoming"

    fun notify(context: Context, address: String, body: String) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "SMS", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Incoming SMS messages"
                enableVibration(true)
                enableLights(true)
            }
            nm.createNotificationChannel(channel)
        }

        val title = contactName(context, address) ?: address.ifBlank { "New message" }

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val contentIntent = if (launch != null) {
            PendingIntent.getActivity(
                context, address.hashCode(), launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else null

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()

        try {
            NotificationManagerCompat.from(context).notify(address.hashCode(), notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted — nothing we can do here.
        }
    }

    /** Best-effort contact-name lookup so the title shows the name, not the number. */
    private fun contactName(context: Context, address: String): String? {
        if (address.isBlank()) return null
        return try {
            val uri = android.net.Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                android.net.Uri.encode(address),
            )
            context.contentResolver.query(
                uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0)?.ifBlank { null } else null }
        } catch (e: Exception) {
            android.util.Log.w(Constants.logTag, "contactName lookup failed", e)
            null
        }
    }
}
