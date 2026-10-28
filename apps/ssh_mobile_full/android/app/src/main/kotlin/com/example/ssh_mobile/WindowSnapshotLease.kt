package com.example.ssh_mobile

/** Window-local lease; failed restoration retains the original snapshot. */
internal class WindowSnapshotLease<S>(
    private val read: () -> S,
    private val enter: () -> Unit,
    private val restore: (S) -> Unit,
) {
    private var current: Pair<Long, S>? = null

    fun setFullscreen(leaseId: Long, enabled: Boolean): Boolean {
        if (leaseId <= 0) return false
        val previous = current
        if (!enabled) return previous == null || previous.first != leaseId || close()
        if (previous != null) return previous.first == leaseId
        return try {
            current = leaseId to read()
            enter()
            true
        } catch (_: Exception) {
            close()
            false
        }
    }

    fun refresh(): Boolean {
        if (current == null) return true
        return try { enter(); true } catch (_: Exception) { false }
    }

    /** Shows the saved window state without releasing the lease. */
    fun suspend(): Boolean {
        val previous = current ?: return true
        return try {
            restore(previous.second)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun close(): Boolean {
        val previous = current ?: return true
        return try {
            restore(previous.second)
            current = null
            true
        } catch (_: Exception) { false }
    }
}
