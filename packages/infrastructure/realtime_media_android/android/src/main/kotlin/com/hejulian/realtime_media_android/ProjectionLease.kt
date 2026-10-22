package com.hejulian.realtime_media_android

import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.content.Intent
import android.os.Handler
import android.os.Looper

internal fun projectionFailureCode(error: Exception): String =
    if (error is SecurityException) "permission_denied" else "backend_failure"

internal enum class ProjectionLeaseState {
    GRANTED,
    CONSUMED,
    REVOKED,
    RELEASED,
}

/**
 * Applies pre-consume projection cleanup only to the lease captured by the
 * failing operation. The action is already bound to that lease by the caller.
 */
internal fun compensateCapturedProjectionGrant(
    capturedLease: Any?,
    currentLease: Any?,
    capturedState: ProjectionLeaseState?,
    releaseIfGranted: () -> Boolean,
): Boolean {
    if (capturedLease == null ||
        capturedLease !== currentLease ||
        capturedState != ProjectionLeaseState.GRANTED
    ) {
        return false
    }
    return releaseIfGranted()
}

internal data class ProjectionLeaseRevocation(
    val changed: Boolean,
    val ownerToken: Long?,
)

/** Pure one-shot ownership state used by the platform projection lease. */
internal class ProjectionLeaseStateMachine {
    private val lock = Any()
    private var stateValue = ProjectionLeaseState.GRANTED
    private var ownerTokenValue: Long? = null
    private var capturedSizeValue: Pair<Int, Int>? = null

    val capturedSize: Pair<Int, Int>?
        get() = synchronized(lock) { capturedSizeValue }

    fun updateCapturedSize(width: Int, height: Int): Boolean = synchronized(lock) {
        if (width <= 0 || height <= 0 ||
            stateValue !in setOf(ProjectionLeaseState.GRANTED, ProjectionLeaseState.CONSUMED)) {
            return@synchronized false
        }
        capturedSizeValue = width to height
        true
    }

    val state: ProjectionLeaseState
        get() = synchronized(lock) { stateValue }

    val ownerToken: Long?
        get() = synchronized(lock) { ownerTokenValue }

    fun consume(owner: Long): Boolean = synchronized(lock) {
        if (stateValue != ProjectionLeaseState.GRANTED) return@synchronized false
        stateValue = ProjectionLeaseState.CONSUMED
        ownerTokenValue = owner
        true
    }

    fun revoke(): ProjectionLeaseRevocation = synchronized(lock) {
        if (stateValue == ProjectionLeaseState.REVOKED ||
            stateValue == ProjectionLeaseState.RELEASED
        ) {
            return@synchronized ProjectionLeaseRevocation(false, null)
        }
        stateValue = ProjectionLeaseState.REVOKED
        capturedSizeValue = null
        ProjectionLeaseRevocation(true, ownerTokenValue)
    }

    fun release(): Boolean = synchronized(lock) {
        if (stateValue == ProjectionLeaseState.RELEASED) return@synchronized false
        stateValue = ProjectionLeaseState.RELEASED
        capturedSizeValue = null
        ownerTokenValue = null
        true
    }

    fun releaseIfGranted(): Boolean = synchronized(lock) {
        if (stateValue != ProjectionLeaseState.GRANTED) return@synchronized false
        stateValue = ProjectionLeaseState.RELEASED
        capturedSizeValue = null
        ownerTokenValue = null
        true
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
    companion object {
        fun create(
            manager: MediaProjectionManager,
            resultCode: Int,
            data: Intent,
            onRevoked: (ProjectionLease, Long?) -> Unit,
            onReleased: (ProjectionLease) -> Unit,
        ): ProjectionLease {
            val projection = manager.getMediaProjection(resultCode, data)
                ?: throw SecurityException("Projection grant unavailable")
            lateinit var lease: ProjectionLease
            val callback = object : MediaProjection.Callback() {
                override fun onStop() { lease.revoke() }
                override fun onCapturedContentResize(width: Int, height: Int) {
                    lease.updateCapturedSize(width, height)
                }
            }
            lease = ProjectionLease(projection, callback,
                onRevoked = { onRevoked(lease, it) },
                onReleased = { onReleased(lease) })
            try {
                projection.registerCallback(callback, Handler(Looper.getMainLooper()))
            } catch (error: Exception) {
                lease.releaseAfterResources()
                throw error
            }
            return lease
        }
    }

    private val stateMachine = ProjectionLeaseStateMachine()
    val capturedSize: Pair<Int, Int>?
        get() = stateMachine.capturedSize

    private fun updateCapturedSize(width: Int, height: Int) {
        stateMachine.updateCapturedSize(width, height)
    }

    val state: ProjectionLeaseState
        get() = stateMachine.state

    val ownerToken: Long?
        get() = stateMachine.ownerToken

    fun consume(owner: Long): Boolean = stateMachine.consume(owner)

    fun revoke() {
        val revocation = stateMachine.revoke()
        if (revocation.changed) onRevoked(revocation.ownerToken)
    }

    fun releaseAfterResources() {
        if (!stateMachine.release()) return
        teardownProjection()
    }

    fun releaseIfGranted(): Boolean {
        if (!stateMachine.releaseIfGranted()) return false
        teardownProjection()
        return true
    }

    private fun teardownProjection() {
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
