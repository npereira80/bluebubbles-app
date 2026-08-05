package com.bluebubbles.messaging.wear

import android.content.Context
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable

/**
 * Provisions the TN Watch app with credentials for both backends over the Wear
 * Data Layer. Dart pushes the current config here (see the "tnwatch/provision"
 * MethodChannel in MainActivity); we cache it and publish a DataItem the watch
 * reads. The watch can also request a fresh push (see WatchConfigListenerService).
 */
object WatchProvisioner {
    private const val PREFS = "tnwatch_provision"
    private const val PATH = "/tnwatch/config"
    private val KEYS = listOf("syncUrl", "syncSecret", "syncToken", "bbUrl", "bbPassword")

    /** Cache the latest config from Dart and immediately push it to the watch. */
    fun cache(context: Context, config: Map<String, String?>) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for (k in KEYS) editor.putString(k, config[k] ?: "")
        editor.apply()
        push(context)
    }

    /** Publish the cached config as a DataItem (idempotent; ts forces a change). */
    fun push(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val request = PutDataMapRequest.create(PATH).apply {
            for (k in KEYS) dataMap.putString(k, prefs.getString(k, "") ?: "")
            dataMap.putLong("ts", System.currentTimeMillis())
        }
        Wearable.getDataClient(context).putDataItem(request.asPutDataRequest().setUrgent())
    }
}
