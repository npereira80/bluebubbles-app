package com.bluebubbles.messaging.services.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

/**
 * SIM presence, the subscriber phone number (when the carrier/SIM exposes it),
 * and the ICCID. `simKey` (used by the server to elect the primary device
 * across SIM swaps) prefers the phone number, else the ICCID.
 */
object SimInfo {

    fun read(context: Context): Map<String, Any?> {
        // Airplane mode (or no cellular radio) means we can't transmit even with a
        // SIM in the tray — such a device must relay sends through the primary.
        val airplane = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0
        } catch (_: Exception) { false }

        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return mapOf("present" to false, "canSend" to false, "airplaneMode" to airplane,
                            "simKey" to null, "number" to null, "iccid" to null)
        val present = tm.simState == TelephonyManager.SIM_STATE_READY
        if (!present) return mapOf("present" to false, "canSend" to false, "airplaneMode" to airplane,
                                   "simKey" to null, "number" to null, "iccid" to null)

        val number = phoneNumber(context)
        val iccid = iccid(context)
        val key = number?.takeIf { it.isNotBlank() } ?: iccid
        // canSend = SIM ready AND radio available (not airplane mode).
        return mapOf("present" to true, "canSend" to !airplane, "airplaneMode" to airplane,
                     "simKey" to key, "number" to number, "iccid" to iccid)
    }

    private fun granted(context: Context, perm: String) =
        ContextCompat.checkSelfPermission(context, perm) == PackageManager.PERMISSION_GRANTED

    private fun phoneNumber(context: Context): String? {
        // Any one of these is enough for the number getters (we're also the
        // default SMS app, which holds READ_SMS).
        if (!granted(context, Manifest.permission.READ_PHONE_NUMBERS) &&
            !granted(context, Manifest.permission.READ_PHONE_STATE) &&
            !granted(context, Manifest.permission.READ_SMS)) return null
        return try {
            val sm = context.getSystemService(SubscriptionManager::class.java) ?: return null
            val subs = sm.activeSubscriptionInfoList ?: emptyList()
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

            // Carriers store the MSISDN in different places — the SIM (UICC), the
            // carrier's records, or IMS. The default getPhoneNumber() often comes
            // back empty when only one of these is populated, so try each source
            // across every active subscription and take the first real number.
            for (info in subs) {
                val subId = info.subscriptionId
                val candidates = mutableListOf<String?>()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    candidates += runCatching { sm.getPhoneNumber(subId) }.getOrNull()
                    candidates += runCatching {
                        sm.getPhoneNumber(subId, SubscriptionManager.PHONE_NUMBER_SOURCE_CARRIER)
                    }.getOrNull()
                    candidates += runCatching {
                        sm.getPhoneNumber(subId, SubscriptionManager.PHONE_NUMBER_SOURCE_UICC)
                    }.getOrNull()
                    candidates += runCatching {
                        sm.getPhoneNumber(subId, SubscriptionManager.PHONE_NUMBER_SOURCE_IMS)
                    }.getOrNull()
                }
                // Legacy per-subscription line number (works on some devices/carriers
                // where the modern API returns blank).
                if (tm != null) {
                    candidates += runCatching {
                        @Suppress("DEPRECATION")
                        tm.createForSubscriptionId(subId).line1Number
                    }.getOrNull()
                }
                @Suppress("DEPRECATION")
                candidates += info.number

                val found = candidates.firstOrNull { !it.isNullOrBlank() }
                if (found != null) return found.trim()
            }

            // Final fallback: default-subscription line number.
            @Suppress("DEPRECATION")
            tm?.line1Number?.takeIf { it.isNotBlank() }?.trim()
        } catch (_: Exception) {
            null
        }
    }

    private fun iccid(context: Context): String? {
        if (!granted(context, Manifest.permission.READ_PHONE_STATE)) return null
        return try {
            val sm = context.getSystemService(SubscriptionManager::class.java)
            sm?.activeSubscriptionInfoList?.firstOrNull()?.iccId?.takeIf { it.isNotBlank() }
        } catch (_: SecurityException) {
            null
        }
    }
}
