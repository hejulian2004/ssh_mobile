package com.hejulian.realtime_media_android

import java.util.concurrent.TimeUnit

internal fun AndroidMediaOwner.stopCapture(): String? {
    if (identity.direction != "send") return null
    // A resize may hold the resource lock while configuring a codec. Publish
    // cancellation first so it cannot attach a late replacement input.
    captureRunning.set(false)
    val worker = synchronized(lock) {
        encoderThread to encoderStopAck
    }
    val thread = worker.first
    val ack = worker.second
    if (thread != null && thread !== Thread.currentThread()) {
        thread.interrupt()
        try {
            if (ack == null || !ack.await(2_000, TimeUnit.MILLISECONDS)) {
                markCleanupDeferred("Encoder worker did not reach a safe point.")
                return "cleanup_deferred"
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            markCleanupDeferred("Encoder worker termination was interrupted.")
            return "cleanup_deferred"
        }
    } else if (thread === Thread.currentThread()) {
        markCleanupDeferred("Encoder worker cannot release itself.")
        return "cleanup_deferred"
    }
    releaseEncoderResources()
    val status = NativeMediaBridge.stopOwner(token)
    if (status != 0 && status != -12) return statusCode(status)
    clearDeferredCleanup()
    return null
}

internal fun AndroidMediaOwner.stopDecoder(): String? {
    if (identity.direction != "receive") return null
    decoderRunning.set(false)
    val worker = synchronized(lock) {
        decoderResetRequested.set(false)
        decoderThread to decoderStopAck
    }
    val thread = worker.first
    val ack = worker.second
    if (thread != null && thread !== Thread.currentThread()) {
        thread.interrupt()
        try {
            if (ack == null || !ack.await(2_000, TimeUnit.MILLISECONDS)) {
                markCleanupDeferred("Decoder worker did not reach a safe point.")
                return "cleanup_deferred"
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            markCleanupDeferred("Decoder worker termination was interrupted.")
            return "cleanup_deferred"
        }
    } else if (thread === Thread.currentThread()) {
        markCleanupDeferred("Decoder worker cannot release itself.")
        return "cleanup_deferred"
    }
    releaseDecoderResources()
    clearDeferredCleanup()
    return null
}

internal fun AndroidMediaOwner.releaseEncoderResources() {
    var lease: ProjectionLease? = null
    synchronized(lock) {
        try {
            virtualDisplay?.release()
        } catch (_: Exception) {
            // Release remains idempotent after a revoked projection.
        }
        virtualDisplay = null
        try {
            encoder?.stop()
        } catch (_: Exception) {
            // A failed codec is already terminal.
        }
        try {
            encoder?.release()
        } catch (_: Exception) {
            // Keep teardown best-effort and retry-safe.
        }
        encoder = null
        try {
            encoderSurface?.release()
        } catch (_: Exception) {
            // Surface may already be released by MediaCodec.
        }
        encoderSurface = null
        lease = projectionLease
        projectionLease = null
        targetBitrateKbps = 0
        targetFramerate = 30
        lastEncoderRecoveryRequestNanos = Long.MIN_VALUE
        encoderThread = null
        encoderStopAck = null
    }
    lease?.releaseAfterResources()
}

internal fun AndroidMediaOwner.releaseDecoderResources() {
    synchronized(lock) {
        try {
            decoder?.stop()
        } catch (_: Exception) {
            // Decoder teardown is idempotent.
        }
        try {
            decoder?.release()
        } catch (_: Exception) {
            // Preserve the terminal failure and release the remaining resources.
        }
        decoder = null
        try {
            decoderSurface?.release()
        } catch (_: Exception) {
            // Surface teardown is idempotent.
        }
        decoderSurface = null
        textureEntry?.setOnFrameConsumedListener(null)
        textureEntry?.release()
        textureEntry = null
        playbackServiceEpoch = null
        pendingDecoderFrame.clear()
        decoderThread = null
        decoderStopAck = null
    }
}
