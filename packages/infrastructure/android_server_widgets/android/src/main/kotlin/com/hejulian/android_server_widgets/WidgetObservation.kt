package com.hejulian.android_server_widgets

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow

data class WidgetObservation(
    val connectionId: String?,
    val server: WidgetServer?,
    val snapshot: MonitorSnapshot?,
)

/** A composition-owned budget also gates active Glance Flow recompositions.
 * No worker, timer or monitor is created; the next existing data event retries. */
fun Flow<WidgetObservation>.limitWidgetRefresh(
    widgetId: Int,
    clock: () -> Long = System::currentTimeMillis,
): Flow<WidgetObservation> = flow {
    val planner = WidgetRefreshPlanner()
    var unconfigured = false
    collect { observation ->
        val connectionId = observation.connectionId
        if (connectionId == null) {
            planner.plan(emptyMap(), emptyMap(), clock())
            if (!unconfigured) emit(observation)
            unconfigured = true
        } else {
            unconfigured = false
            val state = observation.server?.let {
                WidgetRefreshState(it.displayName, observation.snapshot?.status ?: MonitorStatus.notStarted,
                    observation.snapshot?.sampledAt, observation.snapshot?.effectiveIntervalMs ?: 10000)
            }
            val states = if (state == null) emptyMap() else mapOf(connectionId to state)
            if (widgetId in planner.plan(mapOf(widgetId to connectionId), states, clock())) emit(observation)
        }
    }
}
