package com.hejulian.realtime_media_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ResultReceiver
import android.os.SystemClock

/** Retains remote video playback, without a Flutter isolate or network runtime. */
internal class ScreenReceiveForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "ssh_mobile_screen_receive"
        private const val NOTIFICATION_ID = 41_744
        private const val READY_RECEIVER = "ready_receiver"
        private const val STATUS_RECEIVER = "status_receiver"
        const val EPOCH = "service_epoch"
        const val STOPPED = 20

        fun startWhenReady(context: Context, observer: ResultReceiver, ready: (Int, Long) -> Unit) {
            val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
                override fun onReceiveResult(code: Int, data: Bundle?) {
                    ready(code, data?.getLong(EPOCH) ?: 0L)
                }
            }
            val intent = Intent(context, ScreenReceiveForegroundService::class.java)
                .putExtra(READY_RECEIVER, receiver).putExtra(STATUS_RECEIVER, observer)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        }

        fun stopIfUnused(context: Context, owners: Collection<AndroidMediaOwner>) {
            if (owners.none { it.isReceiveRetentionActive() }) {
                context.stopService(Intent(context, ScreenReceiveForegroundService::class.java))
            }
        }
    }

    private val epoch = SystemClock.elapsedRealtimeNanos()
    private var observer: ResultReceiver? = null
    private var power: MediaPlaybackPowerLocks? = null
    private var foreground = false

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val ready = intent?.getParcelableExtra<ResultReceiver>(READY_RECEIVER)
        observer = intent?.getParcelableExtra(STATUS_RECEIVER) ?: observer
        val identity = Bundle().apply { putLong(EPOCH, epoch) }
        try {
            if (!foreground) {
                startPlaybackForeground()
                val locks = MediaPlaybackPowerLocks(this) { stopSelf() }
                power = locks
                locks.acquire()
                foreground = true
            }
            ready?.send(ForegroundReadinessRequest.READY, identity)
        } catch (_: SecurityException) {
            ready?.send(ForegroundReadinessRequest.DENIED, identity)
            stopSelf()
        } catch (_: Exception) {
            ready?.send(ForegroundReadinessRequest.FAILED, identity)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try { power?.close() } finally {
            power = null
            observer?.send(STOPPED, Bundle().apply { putLong(EPOCH, epoch) })
            observer = null
            super.onDestroy()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    private fun startPlaybackForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, getString(R.string.realtime_media_receive_channel), NotificationManager.IMPORTANCE_LOW))
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        builder.setContentTitle(getString(R.string.realtime_media_share_active))
            .setContentText(getString(R.string.realtime_media_receive_active))
            .setSmallIcon(android.R.drawable.ic_menu_view).setOngoing(true)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, builder.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else startForeground(NOTIFICATION_ID, builder.build())
    }
}
