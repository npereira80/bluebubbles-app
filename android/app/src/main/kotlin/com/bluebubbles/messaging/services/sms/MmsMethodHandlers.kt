package com.bluebubbles.messaging.services.sms

import android.content.Context
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method-channel handlers for MMS (TN Messages fork). Registered in
 * MethodCallHandler.dispatchHandler. The Dart SmsService is the only caller;
 * it reads MMS metadata with `mms-query`, then pulls each media part's bytes
 * with `mms-part-bytes` to upload to the sync server.
 */

/** Read MMS history since a timestamp (ms). Arg: since:Long. */
class MmsQueryHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "mms-query" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val since = (call.argument<Any>("since") as? Number)?.toLong() ?: 0L
        result.success(MmsProvider.readSince(context, since))
    }
}

/** Raw bytes of one MMS media part. Arg: partId:Long. Returns ByteArray or null. */
class MmsPartBytesHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "mms-part-bytes" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val partId = (call.argument<Any>("partId") as? Number)?.toLong()
        if (partId == null) { result.error("mms_part_bad_args", "partId required", null); return }
        result.success(MmsProvider.partBytes(context, partId))
    }
}

/**
 * Send an MMS (text + media). Args: addresses:List<String>, text:String,
 * parts:List<{bytes:ByteArray, mime:String, name:String?}>.
 */
class MmsSendHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "mms-send" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val addresses = call.argument<List<String>>("addresses") ?: emptyList()
        val text = call.argument<String>("text") ?: ""
        val parts = call.argument<List<Map<String, Any?>>>("parts") ?: emptyList()
        val messageId = call.argument<String>("messageId")
        if (addresses.isEmpty()) { result.error("mms_send_bad_args", "addresses required", null); return }
        val media = parts.mapNotNull { p ->
            val bytes = p["bytes"] as? ByteArray ?: return@mapNotNull null
            val mime = (p["mime"] as? String) ?: "application/octet-stream"
            MmsSender.Part(bytes, mime, p["name"] as? String)
        }
        try {
            MmsSender.send(context, addresses, text, media, messageId)
            result.success(true)
        } catch (e: Exception) {
            result.error("mms_send_failed", e.message, null)
        }
    }
}

/** Delete an MMS from the provider by _id (so a UI/remote delete isn't re-synced). Arg: id:Long. */
class MmsDeleteHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "mms-delete" }
    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val id = (call.argument<Any>("id") as? Number)?.toLong()
        if (id == null) { result.error("mms_delete_bad_args", "id required", null); return }
        result.success(MmsProvider.deleteById(context, id))
    }
}
