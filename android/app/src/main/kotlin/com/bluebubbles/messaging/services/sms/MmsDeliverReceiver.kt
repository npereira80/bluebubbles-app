package com.bluebubbles.messaging.services.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.bluebubbles.messaging.Constants

/**
 * Default-app MMS delivery. Required for the default-SMS-app contract. Full MMS
 * (media/group) persistence + sync is a later phase; for now we acknowledge the
 * broadcast so delivery isn't dropped.
 */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d(Constants.logTag, "WAP_PUSH_DELIVER (MMS) received — persistence deferred to a later phase")
        // TODO(mms): download + persist MMS parts, notify Dart.
    }
}
