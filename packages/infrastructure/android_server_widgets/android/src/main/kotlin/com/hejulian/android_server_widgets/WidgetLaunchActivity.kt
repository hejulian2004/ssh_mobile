package com.hejulian.android_server_widgets

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Private PendingIntent target; forwards only an existing native binding. */
class WidgetLaunchActivity : Activity() {
    private val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        owner.launch {
            try {
                val connectionId = MonitorSnapshotStorage.instances(this@WidgetLaunchActivity).connectionFor(widgetId)
                val launch = packageManager.getLaunchIntentForPackage(packageName)
                if (launch != null) {
                    launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    if (connectionId != null) {
                        launch.action = WidgetNavigationInbox.ACTION_OPEN_MONITOR
                        launch.putExtra(WidgetNavigationInbox.EXTRA_CONNECTION_ID, connectionId)
                        launch.putExtra(WidgetNavigationInbox.EXTRA_REQUEST_ID, UUID.randomUUID().toString())
                    }
                    startActivity(launch)
                }
            } catch (_: Exception) {
                // A failed local read or missing launcher target cannot start
                // a connection or expose unvalidated Intent arguments.
            } finally { finish() }
        }
    }

    override fun onDestroy() { owner.cancel(); super.onDestroy() }
}
