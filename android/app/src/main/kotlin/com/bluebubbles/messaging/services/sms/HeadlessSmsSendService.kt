package com.bluebubbles.messaging.services.sms

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.telephony.TelephonyManager
import android.util.Log
import com.bluebubbles.messaging.Constants
import java.util.UUID

/**
 * Handles ACTION_RESPOND_VIA_MESSAGE (quick-reply from the dialer / other apps)
 * — required by the default-SMS-app contract. Extracts the recipients + text
 * and sends via [SmsSender].
 */
class HeadlessSmsSendService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null && intent.action == TelephonyManager.ACTION_RESPOND_VIA_MESSAGE) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            val uri = intent.data
            val recipients = uri?.schemeSpecificPart
                ?.split(";", ",")
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?: emptyList()
            if (!text.isNullOrEmpty()) {
                for (address in recipients) {
                    SmsSender.send(this, "quickreply:${UUID.randomUUID()}", address, text)
                }
            }
            Log.d(Constants.logTag, "RESPOND_VIA_MESSAGE handled for ${recipients.size} recipient(s)")
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }
}
