package com.bluebubbles.messaging.garmin

import android.content.Context
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import org.json.JSONArray
import org.json.JSONObject

/**
 * Serves the Garmin watch app over Bluetooth, via the Connect IQ Mobile SDK.
 *
 * The watch can't practically use our HTTP API (Connect IQ caps responses near
 * 32KB and charges double to parse them, and BlueBubbles' chat list is far
 * bigger), and it has no iMessage access of its own. So the phone — which already
 * holds both SMS and iMessage — answers the watch directly.
 *
 * Requests arrive here even when the Flutter engine is asleep, so we answer from
 * a snapshot Dart hands us (see garmin_snapshot.dart) rather than querying the
 * database on demand. Replies are sliced into small messages because a Connect IQ
 * message only carries a couple of KB.
 */
object GarminBridge {
    private const val TAG = "TnGarmin"

    /** Must match the id in the Garmin app's manifest.xml. */
    private const val WATCH_APP_ID = "1c53d80690804bbba0ceace05c78a90d"

    private const val CHATS_PER_MESSAGE = 5
    private const val MESSAGES_PER_MESSAGE = 5

    private var connectIQ: ConnectIQ? = null
    private var ready = false
    private val watchApp = IQApp(WATCH_APP_ID)

    // Last snapshot from Dart, already in the shape the watch expects.
    @Volatile private var chats: List<Map<String, Any>> = emptyList()
    @Volatile private var messages: Map<String, List<Map<String, Any>>> = emptyMap()

    /** Sends outbound replies. Set by the Flutter side so we can reuse its
     *  existing SMS/iMessage send paths instead of duplicating them here. */
    @Volatile var sender: ((chatKey: String, service: String, body: String) -> Unit)? = null

    // ---- lifecycle --------------------------------------------------------

    fun start(context: Context) {
        if (connectIQ != null) return
        val instance = ConnectIQ.getInstance(context, ConnectIQ.IQConnectType.WIRELESS)
        connectIQ = instance
        try {
            instance.initialize(context, /* showUi = */ false, object : ConnectIQ.ConnectIQListener {
                override fun onSdkReady() {
                    ready = true
                    registerForDevices(instance)
                }

                override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus?) {
                    Log.w(TAG, "Connect IQ init failed: $status (Garmin Connect installed?)")
                }

                override fun onSdkShutDown() {
                    ready = false
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "Connect IQ start failed: ${e.message}")
        }
    }

    private fun registerForDevices(instance: ConnectIQ) {
        val devices = try {
            instance.connectedDevices ?: emptyList()
        } catch (e: Exception) {
            Log.w(TAG, "connectedDevices failed: ${e.message}")
            emptyList()
        }
        for (device in devices) {
            try {
                instance.registerForAppEvents(device, watchApp) { iqDevice, _, data, _ ->
                    handleRequest(instance, iqDevice, data)
                }
            } catch (e: Exception) {
                Log.w(TAG, "registerForAppEvents failed: ${e.message}")
            }
        }
    }

    // ---- snapshot from Dart ----------------------------------------------

    /** Replaces the served snapshot. [json] is {chats:[…], messages:{key:[…]}}. */
    fun updateSnapshot(json: String) {
        try {
            val root = JSONObject(json)
            chats = jsonArrayToMaps(root.optJSONArray("chats"))

            val messagesObject = root.optJSONObject("messages")
            val built = HashMap<String, List<Map<String, Any>>>()
            if (messagesObject != null) {
                for (key in messagesObject.keys()) {
                    built[key] = jsonArrayToMaps(messagesObject.optJSONArray(key))
                }
            }
            messages = built
        } catch (e: Exception) {
            Log.w(TAG, "bad snapshot: ${e.message}")
        }
    }

    /** Nudges the watch that something new arrived (ignored if it isn't open). */
    fun notifyNew() {
        val instance = connectIQ ?: return
        if (!ready) return
        for (device in safeDevices(instance)) {
            send(instance, device, mapOf("t" to "new"))
        }
    }

    // ---- request handling -------------------------------------------------

    private fun handleRequest(instance: ConnectIQ, device: IQDevice?, data: List<Any>?) {
        if (device == null || data.isNullOrEmpty()) return
        val request = data.firstOrNull() as? Map<*, *> ?: return
        when (request["q"]?.toString()) {
            "chats" -> sendChats(instance, device)
            "msgs" -> sendMessages(instance, device, request["c"]?.toString() ?: "")
            "send" -> {
                val key = request["c"]?.toString() ?: return
                val service = request["s"]?.toString() ?: "sms"
                val body = request["b"]?.toString() ?: return
                sender?.invoke(key, service, body)
                send(instance, device, mapOf("t" to "sent"))
            }
        }
    }

    private fun sendChats(instance: ConnectIQ, device: IQDevice) {
        val slices = chats.chunked(CHATS_PER_MESSAGE)
        if (slices.isEmpty()) {
            send(instance, device, mapOf("t" to "c", "n" to 0, "k" to 1, "v" to emptyList<Any>()))
            return
        }
        slices.forEachIndexed { index, slice ->
            send(instance, device, mapOf("t" to "c", "n" to index, "k" to slices.size, "v" to slice))
        }
    }

    private fun sendMessages(instance: ConnectIQ, device: IQDevice, chatKey: String) {
        val thread = messages[chatKey].orEmpty()
        val slices = thread.chunked(MESSAGES_PER_MESSAGE)
        if (slices.isEmpty()) {
            send(instance, device, mapOf("t" to "m", "c" to chatKey, "n" to 0, "k" to 1, "v" to emptyList<Any>()))
            return
        }
        slices.forEachIndexed { index, slice ->
            send(
                instance, device,
                mapOf("t" to "m", "c" to chatKey, "n" to index, "k" to slices.size, "v" to slice),
            )
        }
    }

    // ---- plumbing ---------------------------------------------------------

    private fun send(instance: ConnectIQ, device: IQDevice, payload: Map<String, Any>) {
        try {
            instance.sendMessage(device, watchApp, payload) { _, _, status ->
                if (status != ConnectIQ.IQMessageStatus.SUCCESS) {
                    Log.w(TAG, "sendMessage: $status")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "sendMessage failed: ${e.message}")
        }
    }

    private fun safeDevices(instance: ConnectIQ): List<IQDevice> = try {
        instance.connectedDevices ?: emptyList()
    } catch (e: Exception) {
        emptyList()
    }

    private fun jsonArrayToMaps(array: JSONArray?): List<Map<String, Any>> {
        if (array == null) return emptyList()
        val out = ArrayList<Map<String, Any>>(array.length())
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            val map = HashMap<String, Any>()
            for (key in item.keys()) {
                item.opt(key)?.let { map[key] = it }
            }
            out.add(map)
        }
        return out
    }
}
