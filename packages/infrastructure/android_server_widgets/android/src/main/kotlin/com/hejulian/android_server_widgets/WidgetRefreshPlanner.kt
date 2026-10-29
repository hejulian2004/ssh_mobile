package com.hejulian.android_server_widgets

data class WidgetRefreshState(
    val displayName: String,
    val status: MonitorStatus,
    val sampledAt: Long?,
    val effectiveIntervalMs: Long,
)

/** Bounds display updates without scheduling work or producing observations. */
class WidgetRefreshPlanner {
    private data class Presented(val connectionId: String, val state: WidgetRefreshState?, val time: Long)
    private val presented = mutableMapOf<Int, Presented>()

    fun plan(
        mappings: Map<Int, String>,
        states: Map<String, WidgetRefreshState>,
        now: Long,
        connectionIds: Set<String> = mappings.values.toSet(),
        force: Boolean = false,
    ): Set<Int> {
        require(mappings.size <= 100)
        presented.keys.retainAll(mappings.keys)
        val result = mutableSetOf<Int>()
        for ((widgetId, connectionId) in mappings) {
            if (connectionId !in connectionIds) continue
            val state = states[connectionId]
            val previous = presented[widgetId]
            val first = previous == null || previous.connectionId != connectionId
            val old = previous?.state
            val statusChanged = old?.status != state?.status || old?.displayName != state?.displayName ||
                old?.effectiveIntervalMs != state?.effectiveIntervalMs
            val firstSample = old?.sampledAt == null && state?.sampledAt != null
            val sampleChanged = old?.sampledAt != state?.sampledAt
            if (force || first || statusChanged || firstSample ||
                now < previous.time || (sampleChanged && now - previous.time >= 15000)) {
                presented[widgetId] = Presented(connectionId, state, now)
                result.add(widgetId)
            }
        }
        return result
    }

    /** A refused system update can be retried on the next existing event. */
    fun invalidate(widgetIds: Set<Int>) { for (id in widgetIds) presented.remove(id) }
}
