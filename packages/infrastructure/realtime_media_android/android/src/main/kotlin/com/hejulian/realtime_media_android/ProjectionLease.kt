package com.hejulian.realtime_media_android

import android.media.projection.MediaProjection

internal enum class ProjectionLeaseState {
    GRANTED,
    CONSUMED,
    REVOKED,
    RELEASED,
}

/** Pure one-shot ownership state used by the platform projection lease. */
internal class ProjectionLeaseStateMachine {
    var state: ProjectionLeaseState = ProjectionLeaseState.GRANTED
        private set

    var ownerToken: Long? = null
        private set

    fun consume(owner: Long): Boolean {
        if (state != ProjectionLeaseState.GRANTED) return false
        state = ProjectionLeaseState.CONSUMED
        ownerToken = owner
        return true
    }

    fun revoke(): Long? {
        if (state == ProjectionLeaseState.REVOKED ||
            state == ProjectionLeaseState.RELEASED
        ) {
            return null
        }
        state = ProjectionLeaseState.REVOKED
        return ownerToken
    }

    fun release(): Boolean {
        if (state == ProjectionLeaseState.RELEASED) return false
        state = ProjectionLeaseState.RELEASED
        ownerToken = null
        return true
    }
}

/**
 * Owns exactly one MediaProjection grant. Resource owners release this lease
 * only after their VirtualDisplay/codec teardown has reached a safe point.
 */
internal class ProjectionLease(
    val mediaProjection: MediaProjection,
    private val callback: MediaProjection.Callback,
    private val onRevoked: (Long?) -> Unit,
    private val onReleased: () -> Unit,
) {
    private val stateMachine = ProjectionLeaseStateMachine()

    val state: ProjectionLeaseState
        get() = stateMachine.state

    val ownerToken: Long?
        get() = stateMachine.ownerToken

    fun consume(owner: Long): Boolean = stateMachine.consume(owner)

    fun revoke() {
        val previous = stateMachine.state
        val owner = stateMachine.revoke()
        if (previous != ProjectionLeaseState.REVOKED &&
            previous != ProjectionLeaseState.RELEASED
        ) {
            onRevoked(owner)
        }
    }

    fun releaseAfterResources() {
        if (!stateMachine.release()) return
        try {
            mediaProjection.unregisterCallback(callback)
        } catch (_: Exception) {
            // A system revoke may already have removed the callback.
        }
        try {
            mediaProjection.stop()
        } catch (_: Exception) {
            // Projection teardown is best-effort and remains terminal.
        }
        onReleased()
    }
}
