package com.hejulian.realtime_media_android

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

/** Service-local locks; they cannot release the SSH service's separate locks. */
@Suppress("DEPRECATION")
internal class MediaPlaybackPowerLocks(context: Context, private val onFailure: () -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private val wake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ssh_mobile:ScreenVideoPlayback")
        .apply { setReferenceCounted(false) }
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "ssh_mobile:ScreenVideoPlaybackWifi")
        ?.apply { setReferenceCounted(false) }
    private var active = false
    private val renew = object : Runnable {
        override fun run() {
            if (!active) return
            try {
                wake.acquire(10 * 60_000L)
                handler.postDelayed(this, 5 * 60_000L)
            } catch (_: Exception) {
                close()
                onFailure()
            }
        }
    }

    fun acquire() {
        if (active) return
        try {
            wake.acquire(10 * 60_000L)
            wifi?.acquire()
            active = true
            handler.postDelayed(renew, 5 * 60_000L)
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    fun close() {
        active = false
        handler.removeCallbacks(renew)
        try { if (wifi?.isHeld == true) wifi.release() } finally {
            if (wake.isHeld) wake.release()
        }
    }
}
