package com.bluebubbles.messaging.wear

import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

/**
 * Answers the watch's "/tnwatch/request-config" message (sent on watch launch)
 * by re-publishing the cached config DataItem.
 */
class WatchConfigListenerService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        when (event.path) {
            REQUEST_PATH -> {
                WatchProvisioner.push(applicationContext)
                // Contact photos never reach the watch's own contacts provider,
                // so ship them from here at the same time.
                WatchAvatarSync.pushAll(applicationContext)
            }
            AVATARS_PATH -> WatchAvatarSync.pushAll(applicationContext)
            // On-demand fallback: the watch asks for one contact's photo (payload
            // is the last-8-digits key) when a chat has no cached avatar.
            ONE_AVATAR_PATH -> {
                val key = String(event.data).trim()
                if (key.isNotEmpty()) WatchAvatarSync.pushOne(applicationContext, key)
            }
        }
    }

    companion object {
        const val REQUEST_PATH = "/tnwatch/request-config"
        const val AVATARS_PATH = "/tnwatch/request-avatars"
        const val ONE_AVATAR_PATH = "/tnwatch/avatar-request"
    }
}
