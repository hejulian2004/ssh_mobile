package com.hejulian.android_server_widgets

import android.content.Context
import android.content.Intent
import android.appwidget.AppWidgetManager
import androidx.glance.appwidget.AppWidgetId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** System Widget callbacks only release that launcher's instance bindings. */
class ServerMonitorWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ServerMonitorWidget()

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AppWidgetManager.ACTION_APPWIDGET_RESTORED) {
            super.onReceive(context, intent)
            return
        }
        val oldIds = intent.getIntArrayExtra(AppWidgetManager.EXTRA_APPWIDGET_OLD_IDS) ?: intArrayOf()
        val newIds = intent.getIntArrayExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS) ?: intArrayOf()
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                MonitorSnapshotStorage.instances(context).restore(oldIds, newIds)
                for (id in newIds) if (id > 0) ServerMonitorWidget().update(context, AppWidgetId(id))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // Invalid restore metadata or unavailable storage must not
                // terminate App-owned monitoring. A normal update can retry
                // rendering the durable bindings; never log private details.
            } finally { pending?.finish() }
        }
    }
}
