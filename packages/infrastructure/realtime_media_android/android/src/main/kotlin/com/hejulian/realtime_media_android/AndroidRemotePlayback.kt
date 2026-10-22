package com.hejulian.realtime_media_android

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import io.flutter.plugin.common.MethodChannel

/** Main-thread adapter borrowing the existing endpoint owner and its decoder. */
internal fun AndroidMediaOwner.attachDecoderWithRetention(
    observer: ResultReceiver,
    isCurrent: () -> Boolean,
    onFinished: () -> Unit,
    result: MethodChannel.Result,
) {
    if (identity.direction != "receive" || pendingViewerStart != null) {
        result.error(if (identity.direction != "receive") "direction_mismatch" else "duplicate_endpoint",
            "Remote video playback cannot start for this owner.", null)
        return
    }
    val handler = Handler(Looper.getMainLooper())
    var serviceEpoch = 0L
    lateinit var request: ForegroundReadinessRequest
    request = ForegroundReadinessRequest(onComplete = { code ->
        if (pendingViewerStart === request) pendingViewerStart = null
        try {
            if (code != ForegroundReadinessRequest.READY || !isCurrent() || serviceEpoch <= 0) {
                val failure = when (code) {
                    ForegroundReadinessRequest.DENIED -> "permission_denied"
                    ForegroundReadinessRequest.CANCELLED -> "stale_owner"
                    else -> "backend_failure"
                }
                result.error(failure, "Remote playback foreground service was not ready.", null)
                return@ForegroundReadinessRequest
            }
            playbackServiceEpoch = serviceEpoch
            // Readiness is asynchronous: the original request's thread-local
            // factory choice has ended, so re-enter the owner's frozen mode.
            val failure = AndroidCodecFactory.withCodecMode(codecMode) { attachDecoder() }
            val surface = if (failure == null) surfaceId() else null
            if (failure != null || surface == null) {
                result.error(failure ?: "backend_failure", "Android video decoder could not start.", null)
            } else result.success(mapOf("surface_id" to surface))
        } catch (_: Exception) {
            result.error("backend_failure", "Remote video playback could not start.", null)
        } finally { onFinished() }
    }, scheduleTimeout = { timeout ->
        val task = Runnable { timeout() }
        handler.postDelayed(task, 10_000)
        val cancel: () -> Unit = { handler.removeCallbacks(task) }
        cancel
    })
    pendingViewerStart = request
    request.start { complete ->
        ScreenReceiveForegroundService.startWhenReady(context, observer) { code, epoch ->
            if (pendingViewerStart === request) {
                serviceEpoch = epoch
                complete(code)
            }
        }
    }
}

internal fun AndroidMediaOwner.isReceiveRetentionActive(): Boolean = synchronized(lock) {
    identity.direction == "receive" && (pendingViewerStart != null || decoderRunning.get() ||
        decoderThread != null || decoder != null || decoderSurface != null || textureEntry != null)
}

internal fun screenPlaybackServiceObserver(owners: () -> Collection<AndroidMediaOwner>): ResultReceiver =
    object : ResultReceiver(Handler(Looper.getMainLooper())) {
        override fun onReceiveResult(code: Int, data: Bundle?) {
            if (code != ScreenReceiveForegroundService.STOPPED) return
            val epoch = data?.getLong(ScreenReceiveForegroundService.EPOCH) ?: return
            for (owner in owners()) {
                if (owner.playbackServiceEpoch == epoch && owner.isReceiveRetentionActive()) {
                    owner.failFromWorker("decoder_failed", "Remote playback foreground service ended.")
                }
            }
        }
    }
