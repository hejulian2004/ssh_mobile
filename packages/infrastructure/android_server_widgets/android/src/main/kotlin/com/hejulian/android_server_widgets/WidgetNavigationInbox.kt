package com.hejulian.android_server_widgets

/** Engine-local routing hints, never connection or command instructions. */
class WidgetNavigationInbox {
    private val pending = ArrayDeque<Map<String, String>>()
    private val seen = linkedSetOf<String>()

    fun offer(action: String?, connectionId: String?, requestId: String?): Boolean {
        if (action != ACTION_OPEN_MONITOR || connectionId == null || !validConnectionId(connectionId) ||
            requestId == null || !Regex("[A-Za-z0-9_-]{1,64}").matches(requestId) || requestId in seen) return false
        seen.add(requestId)
        if (seen.size > 32) seen.remove(seen.first())
        if (pending.size == 8) pending.removeFirst()
        pending.addLast(mapOf(EXTRA_CONNECTION_ID to connectionId, EXTRA_REQUEST_ID to requestId))
        return true
    }

    fun take(): Map<String, String>? = if (pending.isEmpty()) null else pending.removeFirst()

    companion object {
        const val ACTION_OPEN_MONITOR = "com.hejulian.android_server_widgets.OPEN_MONITOR"
        const val EXTRA_CONNECTION_ID = "connectionId"
        const val EXTRA_REQUEST_ID = "requestId"
    }
}
