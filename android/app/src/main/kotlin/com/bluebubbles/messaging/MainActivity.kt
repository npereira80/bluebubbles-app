package com.bluebubbles.messaging

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.services.foreground.ForegroundServiceBroadcastReceiver
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.utils.PersistentLog
import com.google.firebase.firestore.FirebaseFirestoreException
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private val engineLock = Any()
        @Volatile private var _engine: FlutterEngine? = null

        // Whether the Dart side of [_engine] has finished registering its method-call
        // handler (signaled via the "ready" method call — see MethodCallHandler).
        // Always reset to false alongside [_engine] itself so a stale "ready" from a
        // previous engine can never be mistaken for the current one's readiness.
        @Volatile private var _dartReady = false

        fun getEngine(): FlutterEngine? {
            synchronized(engineLock) {
                return _engine
            }
        }

        fun setEngine(newEngine: FlutterEngine?, context: Context) {
            synchronized(engineLock) {
                PersistentLog.d(
                    context,
                    Constants.logTag,
                    "MainActivity engine ${if (newEngine != null) "set (${newEngine.hashCode()})" else "cleared"} — resetting dartReady to false"
                )
                _engine = newEngine
                _dartReady = false
            }
        }

        fun isDartReady(): Boolean {
            synchronized(engineLock) {
                return _dartReady
            }
        }

        fun setDartReady(ready: Boolean, context: Context) {
            synchronized(engineLock) {
                if (_dartReady != ready) {
                    PersistentLog.d(context, Constants.logTag, "MainActivity dartReady changing from $_dartReady to $ready")
                }
                _dartReady = ready
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        setEngine(flutterEngine, this)
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Constants.methodChannel).setMethodCallHandler {
            call, result -> MethodCallHandler().methodCallHandler(call, result, this)
        }

        // TN Watch: receive both backends' config from Dart and provision the
        // watch over the Wear Data Layer.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tnwatch/provision").setMethodCallHandler { call, result ->
            when (call.method) {
                "provision" -> {
                    @Suppress("UNCHECKED_CAST")
                    val raw = call.arguments as? Map<String, Any?> ?: emptyMap()
                    val cfg = raw.mapValues { it.value?.toString() }
                    com.bluebubbles.messaging.wear.WatchProvisioner.cache(this, cfg)
                    result.success(true)
                }
                // Watch App Client screen: live status over Bluetooth, and a
                // command to wipe + re-sync the watch's local database.
                "status" -> com.bluebubbles.messaging.wear.WatchStatusClient.status(this, result)
                "resync" -> com.bluebubbles.messaging.wear.WatchStatusClient.resync(this, result)
                // Force-push every contact photo we have to the watch. Contacts
                // + bitmap work, so keep it off the main thread.
                "pushAvatars" -> {
                    Thread {
                        val sent = com.bluebubbles.messaging.wear.WatchAvatarSync.pushAll(this)
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            result.success(sent)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // Garmin watch app: Dart hands us a compact snapshot to serve over BLE,
        // and we hand outbound replies back to Dart's existing send paths.
        val garminChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tnwatch/garmin")
        com.bluebubbles.messaging.garmin.GarminBridge.start(this)
        com.bluebubbles.messaging.garmin.GarminBridge.sender = { chatKey, service, body ->
            runOnUiThread {
                garminChannel.invokeMethod(
                    "send",
                    mapOf("chatKey" to chatKey, "service" to service, "body" to body),
                )
            }
        }
        garminChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "snapshot" -> {
                    val json = call.argument<String>("json") ?: ""
                    if (json.isNotEmpty()) com.bluebubbles.messaging.garmin.GarminBridge.updateSnapshot(json)
                    result.success(true)
                }
                "notify" -> {
                    com.bluebubbles.messaging.garmin.GarminBridge.notifyNew()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val cause = throwable.cause ?: throwable
            if (cause is FirebaseFirestoreException) {
                when (cause.code) {
                    FirebaseFirestoreException.Code.PERMISSION_DENIED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: PERMISSION_DENIED — missing or insufficient security rules (${cause.message})", cause)
                    FirebaseFirestoreException.Code.UNAVAILABLE ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: UNAVAILABLE — service unreachable, check network connectivity (${cause.message})", cause)
                    FirebaseFirestoreException.Code.UNAUTHENTICATED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: UNAUTHENTICATED — request not authenticated (${cause.message})", cause)
                    FirebaseFirestoreException.Code.NOT_FOUND ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: NOT_FOUND — document or collection does not exist (${cause.message})", cause)
                    FirebaseFirestoreException.Code.CANCELLED ->
                        PersistentLog.d(this, Constants.logTag, "Firestore: CANCELLED — listener was cancelled (${cause.message})")
                    FirebaseFirestoreException.Code.ALREADY_EXISTS ->
                        PersistentLog.w(this, Constants.logTag, "Firestore: ALREADY_EXISTS — document already exists (${cause.message})")
                    FirebaseFirestoreException.Code.RESOURCE_EXHAUSTED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: RESOURCE_EXHAUSTED — quota exceeded (${cause.message})", cause)
                    FirebaseFirestoreException.Code.FAILED_PRECONDITION ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: FAILED_PRECONDITION — operation rejected, check indexes or state (${cause.message})", cause)
                    FirebaseFirestoreException.Code.ABORTED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: ABORTED — transaction conflict or contention (${cause.message})", cause)
                    FirebaseFirestoreException.Code.INTERNAL ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: INTERNAL — internal server error (${cause.message})", cause)
                    FirebaseFirestoreException.Code.DEADLINE_EXCEEDED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: DEADLINE_EXCEEDED — operation timed out (${cause.message})", cause)
                    else ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: unhandled error ${cause.code} (${cause.message})", cause)
                }
            } else {
                defaultHandler?.uncaughtException(thread, throwable)
            }
        }
    }

    override fun onDestroy() {
        PersistentLog.d(this, Constants.logTag, "BlueBubbles MainActivity is being destroyed")
        MethodCallHandler.clearNotificationListenerResult()
        setEngine(null, this)

        // If we are finishing "gracefully", the dart code would have started the foreground service.
        // If we are finishing because the system is destroying the activity, we need to start the foreground service
        // via a broadcast intent.
        if (isFinishing) {
            PersistentLog.d(this, Constants.logTag, "BlueBubbles activity is finishing")
        } else {
            PersistentLog.d(this, Constants.logTag, "BlueBubbles activity is being destroyed by the system")

            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
            val keepAppAlive: Boolean = prefs.getBoolean("keepAppAlive", false)

            // Create an intent to start the foreground service
            if (keepAppAlive) {
                PersistentLog.d(this, Constants.logTag, "Creating broadcast intent to restart the foreground service...")
                val broadcastIntent = Intent(this, ForegroundServiceBroadcastReceiver::class.java)
                broadcastIntent.setAction("restartservice");
                sendBroadcast(broadcastIntent);
            }
        }

        try {
            super.onDestroy()
        } catch (e: ConcurrentModificationException) {
            PersistentLog.e(this, Constants.logTag, "Caught ConcurrentModificationException when destroying MainActivity", e)
        } catch (e: Exception) {
            PersistentLog.e(this, Constants.logTag, "Caught unhandled Exception when destroying MainActivity", e)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == Constants.notificationListenerRequestCode) {
            MethodCallHandler.consumeNotificationListenerResult()?.success(resultCode == Activity.RESULT_OK)
        }
    }
}