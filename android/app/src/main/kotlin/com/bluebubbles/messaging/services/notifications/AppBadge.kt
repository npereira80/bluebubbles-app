package com.bluebubbles.messaging.services.notifications

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Unread count on the launcher icon.
 *
 * Worth knowing what Android actually allows here, because it's less than it
 * sounds. An app cannot draw on its own icon. All it can do is:
 *
 *  1. Put a number on its notifications ([current], read by the notification
 *     builders). Launchers that show counts read that; the rest show a plain dot.
 *     This is the only standards-based route, and it only applies while a
 *     notification is showing.
 *  2. Send an OEM-specific broadcast. Samsung, Oppo/ColorOS, Huawei and Xiaomi
 *     each invented their own, and each has tightened it over the years — on
 *     recent versions these are frequently ignored outright. Sent best-effort.
 *
 * The launcher decides how to render the number, including where it caps it
 * (usually "99+"). An app can't specify the text, so the count is capped at 99
 * before sending rather than letting a launcher print something like 253.
 */
object AppBadge {

    const val MAX = 99

    /** Latest unread count, for the notification builders to stamp on. */
    @Volatile
    var current: Int = 0
        private set

    fun set(context: Context, count: Int) {
        current = count.coerceIn(0, MAX)
        val launcher = launcherClassName(context) ?: return
        sendSamsung(context, current, launcher)
        sendOppo(context, current)
        sendHuawei(context, current, launcher)
    }

    private fun launcherClassName(context: Context): String? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        return intent?.component?.className
    }

    private fun sendSamsung(context: Context, count: Int, launcher: String) {
        runCatching {
            // Also honoured by several AOSP-derived launchers.
            val intent = Intent("android.intent.action.BADGE_COUNT_UPDATE").apply {
                putExtra("badge_count", count)
                putExtra("badge_count_package_name", context.packageName)
                putExtra("badge_count_class_name", launcher)
            }
            context.sendBroadcast(intent)
        }.onFailure { Log.d(Constants.logTag, "Badge: Samsung route unavailable") }
    }

    private fun sendOppo(context: Context, count: Int) {
        // ColorOS. The newer provider call replaced the broadcast; try both, since
        // which one works depends on the ColorOS version.
        runCatching {
            val intent = Intent("com.oppo.unsettledevent").apply {
                putExtra("pakeageName", context.packageName)   // sic — Oppo's spelling
                putExtra("number", count)
                putExtra("upgradeNumber", count)
            }
            context.sendBroadcast(intent)
        }.onFailure { Log.d(Constants.logTag, "Badge: Oppo broadcast unavailable") }

        runCatching {
            val values = ContentValues().apply {
                put("package_name", context.packageName)
                put("app_badge_count", count)
            }
            context.contentResolver.call(
                Uri.parse("content://com.android.badge/badge"),
                "setAppBadgeCount",
                null,
                android.os.Bundle().apply { putInt("app_badge_count", count) },
            ) ?: context.contentResolver.insert(Uri.parse("content://com.android.badge/badge"), values)
        }.onFailure { Log.d(Constants.logTag, "Badge: Oppo provider unavailable") }
    }

    private fun sendHuawei(context: Context, count: Int, launcher: String) {
        runCatching {
            val bundle = android.os.Bundle().apply {
                putString("package", context.packageName)
                putString("class", launcher)
                putInt("badgenumber", count)
            }
            context.contentResolver.call(
                Uri.parse("content://com.huawei.android.launcher.settings/badge/"),
                "change_badge",
                null,
                bundle,
            )
        }.onFailure { Log.d(Constants.logTag, "Badge: Huawei route unavailable") }
    }
}

/** Args: count:Int. Capped at 99 — see [AppBadge]. */
class SetAppBadgeHandler : MethodCallHandlerImpl() {
    companion object { const val tag = "set-app-badge" }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val count = (call.argument<Any>("count") as? Number)?.toInt() ?: 0
        AppBadge.set(context, count)
        result.success(AppBadge.current)
    }
}
