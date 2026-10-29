package com.hejulian.android_server_widgets

import android.content.Context
import androidx.glance.appwidget.AppWidgetId
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Context/Glance glue; the planner owns all display-update decisions. */
object WidgetUpdateDispatcher {
    private val mutex = Mutex()
    private val planner = WidgetRefreshPlanner()

    suspend fun refreshChanged(context: Context, connectionIds: Set<String>, immediate: Boolean = false) = mutex.withLock {
        val mappings = MonitorSnapshotStorage.instances(context).mappings()
        val repository = MonitorSnapshotStorage.repository(context)
        val directory = repository.servers().associateBy { it.connectionId }
        val states = mutableMapOf<String, WidgetRefreshState>()
        for (id in connectionIds) {
            val server = directory[id] ?: continue
            val snapshot = repository.snapshotFor(id)
            states[id] = WidgetRefreshState(
                server.displayName, snapshot?.status ?: MonitorStatus.notStarted,
                snapshot?.sampledAt, snapshot?.effectiveIntervalMs ?: 10000,
            )
        }
        val planned = planner.plan(mappings, states, System.currentTimeMillis(), connectionIds, immediate)
        var firstError: Exception? = null
        for (widgetId in planned) {
            try {
                ServerMonitorWidget().update(context, AppWidgetId(widgetId))
            } catch (error: Exception) {
                planner.invalidate(setOf(widgetId))
                firstError = firstError ?: error
            }
        }
        firstError?.let { throw it }
    }

    /** An imported catalog cannot silently reconnect old widget selections. */
    suspend fun resetConfigurations(context: Context) = mutex.withLock {
        val repository = MonitorSnapshotStorage.instances(context)
        val formerIds = repository.mappings().keys
        repository.clear()
        planner.invalidate(formerIds)
        for (id in formerIds) ServerMonitorWidget().update(context, AppWidgetId(id))
    }
}
