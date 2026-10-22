package com.hejulian.realtime_media_android

/** Called only between output drains by the owner's existing encoder worker. */
internal fun AndroidMediaOwner.resizeCapture(next: Pair<Int, Int>): String? = synchronized(lock) {
    val lease = projectionLease ?: return@synchronized "projection_revoked"
    val display = virtualDisplay ?: return@synchronized "capture_source_ended"
    if (next.first <= 0 || next.second <= 0) return@synchronized "capture_source_ended"
    val active = {
        captureRunning.get() && projectionLease === lease &&
            lease.state == ProjectionLeaseState.CONSUMED
    }
    val replaced = replaceCaptureInput(
        isActive = active,
        detachSurface = { display.surface = null },
        releaseEncoder = {
            try { encoder?.stop() } catch (_: IllegalStateException) { }
            // If release fails, retain the reference for owner cleanup and
            // never allocate a second codec over an unconfirmed resource.
            encoder?.release()
            encoder = null
            encoderSurface?.release()
            encoderSurface = null
        },
        createEncoder = {
            encoderRecoveryGate = H264EncoderRecoveryGate()
            lastEncoderRecoveryRequestNanos = Long.MIN_VALUE
            val codec = AndroidCodecFactory.withCodecMode(codecMode) {
                AndroidCodecFactory.createEncoder(next.first, next.second)
            } ?: throw IllegalStateException("Selected encoder cannot resize")
            encoder = codec
            encoderSurface = codec.createInputSurface()
            codec.start()
            if (setEncoderBitrate(codec, targetBitrateKbps) != null) {
                throw IllegalStateException("Encoder resize could not restore bitrate")
            }
        },
        resizeDisplay = {
            display.resize(next.first, next.second, captureDensityDpi())
        },
        attachSurface = { display.surface = encoderSurface },
    )
    if (!replaced) return@synchronized "projection_revoked"
    captureWidth = next.first
    captureHeight = next.second
    width = next.first
    height = next.second
    null
}
