package com.bluebubbles.messaging.wear

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.MethodChannel

/**
 * Queries the paired TN Watch app over the Wear Data Layer (Bluetooth) for its
 * status, and can ask it to wipe its cache and re-sync. Used by the phone's
 * "Watch App Client" settings screen.
 *
 * Request/response: we send on /tnwatch/status and wait for the watch to answer
 * on /tnwatch/status-reply, with a timeout so an out-of-range watch reports
 * "not available" instead of hanging.
 */
object WatchStatusClient {
    private const val TAG = "TnWatchStatus"
    private const val PATH_STATUS = "/tnwatch/status"
    private const val PATH_STATUS_REPLY = "/tnwatch/status-reply"
    private const val PATH_RESYNC = "/tnwatch/resync"
    private const val TIMEOUT_MS = 6000L

    /** Sends [path] to every connected node and waits for the watch's reply. */
    fun query(context: Context, path: String, result: MethodChannel.Result) {
        val messageClient = Wearable.getMessageClient(context)
        var settled = false

        val listener = object : MessageClient.OnMessageReceivedListener {
            override fun onMessageReceived(event: com.google.android.gms.wearable.MessageEvent) {
                if (event.path != PATH_STATUS_REPLY) return
                if (settled) return
                settled = true
                messageClient.removeListener(this)
                result.success(String(event.data))
            }
        }
        messageClient.addListener(listener)

        Wearable.getNodeClient(context).connectedNodes
            .addOnSuccessListener { nodes ->
                if (nodes.isEmpty()) {
                    if (!settled) {
                        settled = true
                        messageClient.removeListener(listener)
                        result.success(null) // no watch paired / in range
                    }
                    return@addOnSuccessListener
                }
                for (node in nodes) {
                    messageClient.sendMessage(node.id, path, ByteArray(0))
                        .addOnFailureListener { Log.w(TAG, "send $path failed: ${it.message}") }
                }
            }
            .addOnFailureListener {
                if (!settled) {
                    settled = true
                    messageClient.removeListener(listener)
                    result.success(null)
                }
            }

        // Timeout: the watch may be paired but unreachable.
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            if (!settled) {
                settled = true
                messageClient.removeListener(listener)
                result.success(null)
            }
        }, TIMEOUT_MS)
    }

    fun status(context: Context, result: MethodChannel.Result) = query(context, PATH_STATUS, result)
    fun resync(context: Context, result: MethodChannel.Result) = query(context, PATH_RESYNC, result)
}
