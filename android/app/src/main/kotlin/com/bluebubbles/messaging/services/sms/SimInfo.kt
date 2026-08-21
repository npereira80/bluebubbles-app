package com.bluebubbles.messaging.services.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.telephony.ServiceState
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
        logRawState(context, tm)
        val present = simPresent(context, tm)
        if (!present) return mapOf("present" to false, "canSend" to false, "airplaneMode" to airplane,
                                   "inService" to false, "simKey" to null, "number" to null, "iccid" to null,
                                   "countryIso" to countryIso(tm))

        // A SIM in the tray with the radio on still can't send when the device has
        // no coverage. Android would accept the message and hold it in the radio
        // layer, so the app would show it as sent and the user would never learn
        // it hadn't gone anywhere.
        val inService = serviceAvailable(tm)

        val number = phoneNumber(context)
        val iccid = iccid(context)
        // Subscription id as the last resort, because the two preferred keys are
        // both frequently unavailable to a non-privileged app: carriers often
        // never write the MSISDN to the SIM, and ICCID is restricted to system
        // apps on Android 11+. Google's own guidance is to use the subscription
        // id instead. It is less stable across re-insertion, but a null key means
        // the server cannot elect this device as the primary sender at all, which
        // is worse.
        val key = number?.takeIf { it.isNotBlank() }
            ?: iccid?.takeIf { it.isNotBlank() }
            ?: subscriptionKey(context)
        // canSend = SIM ready AND radio available AND actually on a network.
        return mapOf("present" to true, "canSend" to (!airplane && inService), "airplaneMode" to airplane,
                     "inService" to inService, "simKey" to key, "number" to number, "iccid" to iccid,
                     "countryIso" to countryIso(tm))
    }

    /**
     * Whether this device has a usable SIM.
     *
     * `TelephonyManager.simState` only describes the *default* slot, so on a
     * dual-SIM or eSIM phone it reports ABSENT whenever the SIM lives in the
     * other slot — and then nothing here believes the phone can send, the
     * composer never tries the radio, and the message is quietly parked with no
     * error to explain it.
     *
     * An active subscription is the honest signal: it exists per SIM, physical or
     * embedded, regardless of slot. Falls back to the per-slot states and finally
     * to the default slot, so a device that refuses the subscription list still
     * gets an answer.
     */
    /**
     * Log every raw telephony fact behind the SIM decision.
     *
     * Worth having permanently. "No SIM" is reached by several different APIs
     * disagreeing, and on OEM builds some of them return empty rather than
     * throwing even with the permission granted — which is indistinguishable from
     * a genuinely empty tray unless each is printed separately.
     */
    private fun logRawState(context: Context, tm: TelephonyManager) {
        val slots = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) tm.activeModemCount
            else @Suppress("DEPRECATION") tm.phoneCount
        }
        val perSlot = runCatching {
            (0 until (slots.getOrNull() ?: 0)).map { tm.getSimState(it) }
        }
        val subs = runCatching {
            context.getSystemService(SubscriptionManager::class.java)?.activeSubscriptionInfoList?.size
        }
        Log.i(
            Constants.logTag,
            "SimInfo: simState=${runCatching { tm.simState }.getOrNull()} " +
                "slots=${slots.getOrNull() ?: "err:${slots.exceptionOrNull()?.javaClass?.simpleName}"} " +
                "perSlotStates=${perSlot.getOrNull() ?: "err:${perSlot.exceptionOrNull()?.javaClass?.simpleName}"} " +
                "activeSubs=${subs.getOrNull() ?: "err/null:${subs.exceptionOrNull()?.javaClass?.simpleName}"} " +
                "operator='${runCatching { tm.simOperator }.getOrNull()}' " +
                "networkOperator='${runCatching { tm.networkOperator }.getOrNull()}'",
        )
    }

    private fun simPresent(context: Context, tm: TelephonyManager): Boolean {
        runCatching {
            val sm = context.getSystemService(SubscriptionManager::class.java)
            val subs = sm?.activeSubscriptionInfoList
            if (subs != null && subs.isNotEmpty()) return true
        }

        runCatching {
            val slots = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                tm.activeModemCount
            } else {
                @Suppress("DEPRECATION")
                tm.phoneCount
            }
            for (slot in 0 until slots) {
                if (tm.getSimState(slot) == TelephonyManager.SIM_STATE_READY) return true
            }
        }

        return tm.simState == TelephonyManager.SIM_STATE_READY
    }

    /**
     * Whether the device is registered on a cellular network.
     *
     * Treated as available when it can't be determined: a false "no coverage"
     * would divert every message to the relay, which is worse than trying the
     * radio and finding out.
     */
    private fun serviceAvailable(tm: TelephonyManager): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            val state = tm.serviceState ?: return true
            when (state.state) {
                ServiceState.STATE_IN_SERVICE -> true
                ServiceState.STATE_EMERGENCY_ONLY,
                ServiceState.STATE_OUT_OF_SERVICE,
                ServiceState.STATE_POWER_OFF -> false
                else -> true
            }
        } catch (_: SecurityException) {
            true
        } catch (_: Exception) {
            true
        }
    }

    /**
     * The country this line belongs to, as an ISO 3166-1 alpha-2 code.
     *
     * This is what a typed-in national number has to be parsed against. The UI
     * locale is the wrong source and silently corrupts numbers: a Portuguese SIM
     * in a phone set to English gives "en_US", so "916309004" parses as country
     * code 1 and becomes +1916309004 — a number that will never connect.
     *
     * SIM before network, because the SIM says whose line it is while the network
     * only says where the phone currently is (wrong while roaming). Neither
     * requires a permission.
     */
    private fun countryIso(tm: TelephonyManager): String? = try {
        (tm.simCountryIso?.takeIf { it.isNotBlank() }
            ?: tm.networkCountryIso?.takeIf { it.isNotBlank() })
            ?.uppercase()
    } catch (_: Exception) {
        null
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

    /**
     * A key derived from the active subscription, qualified by the operator so it
     * doesn't collide with a different SIM that happens to reuse the id.
     */
    private fun subscriptionKey(context: Context): String? = try {
        val sm = context.getSystemService(SubscriptionManager::class.java)
        val info = sm?.activeSubscriptionInfoList?.firstOrNull()
        info?.let { "sub:${it.subscriptionId}:${it.mcc}${it.mnc}" }
    } catch (_: Exception) {
        null
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
