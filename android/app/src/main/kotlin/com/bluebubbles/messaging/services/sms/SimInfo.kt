package com.bluebubbles.messaging.services.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
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
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return mapOf("present" to false, "simKey" to null, "number" to null, "iccid" to null)
        val present = tm.simState == TelephonyManager.SIM_STATE_READY
        if (!present) return mapOf("present" to false, "simKey" to null, "number" to null, "iccid" to null)

        val number = phoneNumber(context)
        val iccid = iccid(context)
        val key = number?.takeIf { it.isNotBlank() } ?: iccid
        return mapOf("present" to true, "simKey" to key, "number" to number, "iccid" to iccid)
    }

    private fun granted(context: Context, perm: String) =
        ContextCompat.checkSelfPermission(context, perm) == PackageManager.PERMISSION_GRANTED

    private fun phoneNumber(context: Context): String? {
        if (!granted(context, Manifest.permission.READ_PHONE_NUMBERS) &&
            !granted(context, Manifest.permission.READ_PHONE_STATE)) return null
        return try {
            val sm = context.getSystemService(SubscriptionManager::class.java) ?: return null
            val active = sm.activeSubscriptionInfoList?.firstOrNull() ?: return null
            // API 33+ has a dedicated, more reliable getter.
            val modern = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                sm.getPhoneNumber(active.subscriptionId)
            } else null
            modern?.takeIf { it.isNotBlank() }
                ?: run {
                    @Suppress("DEPRECATION")
                    active.number?.takeIf { it.isNotBlank() }
                }
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
