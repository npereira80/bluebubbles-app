package com.bluebubbles.messaging.wear

import android.content.Context
import android.util.Base64
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Performs HTTP requests on behalf of the watch.
 *
 * Off Wi-Fi a Wear watch has no dependable internet route of its own, so the watch
 * app sends us the request over the Data Layer and we run it on the phone's
 * connection (Wi-Fi or mobile data). The response goes back as an Asset, which
 * streams separately from the DataItem and so isn't bound by the ~100KB message
 * limit — important for /delta payloads.
 */
object WatchHttpRelay {
    private const val TAG = "TnWatchRelay"
    private const val REPLY_PREFIX = "/tnwatch/http-reply/"
    private const val TIMEOUT_MS = 30_000

    // Small pool: the watch issues a handful of requests per sync.
    private val executor = Executors.newFixedThreadPool(3)

    /** Handles a "/tnwatch/http" request payload from the watch. */
    fun handle(context: Context, payload: ByteArray) {
        val request = try {
            JSONObject(String(payload))
        } catch (e: Exception) {
            Log.w(TAG, "bad relay request: ${e.message}")
            return
        }
        val id = request.optString("id")
        if (id.isEmpty()) return

        executor.execute {
            var code = 0
            var body = ByteArray(0)
            try {
                val url = URL(request.getString("url"))
                val connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = request.optString("method", "GET")
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    doInput = true
                }
                request.optJSONObject("headers")?.let { headers ->
                    for (name in headers.keys()) {
                        connection.setRequestProperty(name, headers.optString(name))
                    }
                }
                val encodedBody = request.optString("body", "")
                if (encodedBody.isNotEmpty()) {
                    connection.doOutput = true
                    request.optString("contentType").takeIf { it.isNotEmpty() }?.let {
                        connection.setRequestProperty("Content-Type", it)
                    }
                    connection.outputStream.use { it.write(Base64.decode(encodedBody, Base64.NO_WRAP)) }
                }

                code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                body = stream?.use { input ->
                    ByteArrayOutputStream().also { out -> input.copyTo(out) }.toByteArray()
                } ?: ByteArray(0)
                connection.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "relay ${request.optString("url")} failed: ${e.message}")
            }
            reply(context, id, code, body)
        }
    }

    private fun reply(context: Context, id: String, code: Int, body: ByteArray) {
        val put = PutDataMapRequest.create(REPLY_PREFIX + id).apply {
            dataMap.putInt("code", code)
            dataMap.putLong("ts", System.currentTimeMillis())
            dataMap.putAsset("body", Asset.createFromBytes(body))
        }
        Wearable.getDataClient(context).putDataItem(put.asPutDataRequest().setUrgent())
            .addOnFailureListener { Log.w(TAG, "relay reply failed: ${it.message}") }
    }
}
