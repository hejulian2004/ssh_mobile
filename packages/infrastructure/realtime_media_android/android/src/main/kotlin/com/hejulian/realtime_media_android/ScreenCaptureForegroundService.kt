package com.hejulian.realtime_media_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.ResultReceiver
import android.os.Handler
import android.os.Looper
import android.os.Bundle

/** Typed foreground service required while MediaProjection is capturing. */
internal class ScreenCaptureForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "ssh_mobile_screen_share"
        private const val NOTIFICATION_ID = 41_743
        private const val READY_RECEIVER = "projection_ready_receiver"
        const val READY = 0
        const val PERMISSION_DENIED = 1
        const val FAILED = 2

        fun startWhenReady(context: Context, onReady: (Int) -> Unit) {
            start(context, object : ResultReceiver(Handler(Looper.getMainLooper())) {
                override fun onReceiveResult(code: Int, data: Bundle?) { onReady(code) }
            })
        }

        fun start(context: Context, receiver: ResultReceiver? = null) {
            val intent = Intent(context, ScreenCaptureForegroundService::class.java).apply {
                if (receiver != null) putExtra(READY_RECEIVER, receiver)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenCaptureForegroundService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val receiver = intent?.getParcelableExtra<ResultReceiver>(READY_RECEIVER)
        try {
            startProjectionForeground()
            receiver?.send(READY, null)
        } catch (_: SecurityException) {
            receiver?.send(PERMISSION_DENIED, null)
            stopSelf()
        } catch (_: Exception) {
            receiver?.send(FAILED, null)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startProjectionForeground() {
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.realtime_media_share_active))
            .setContentText(getString(R.string.realtime_media_capture_active))
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        GuidanceOverlayRegistry.hide()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.realtime_media_capture_channel),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }
}
