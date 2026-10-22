package com.hejulian.realtime_media_android

import android.media.MediaCodec
import android.media.MediaFormat
import java.util.concurrent.atomic.AtomicBoolean

/** Borrows one owner's decoder; the owner alone releases its resources. */
internal fun AndroidMediaOwner.drainDecoder(frameAvailable: AtomicBoolean) {
    val codec = synchronized(lock) { decoder } ?: return
    val info = MediaCodec.BufferInfo()
    val presentation = DecoderPresentationGate(
        canRender = { frameAvailable.compareAndSet(true, false) },
    ) { index, render ->
        codec.releaseOutputBuffer(index, render)
        if (render) synchronized(lock) { framesRendered++ }
    }
    val pump = DecoderOutputPump(
        isActive = { decoderRunning.get() },
        submitInput = { queueDecoderInput(codec) },
        readOutput = { codec.dequeueOutputBuffer(info, 0) },
        renderOutput = { index ->
            val format = codec.getOutputFormat(index)
            val dimensions = decoderOutputDimensions(
                format.getInteger(MediaFormat.KEY_WIDTH),
                format.getInteger(MediaFormat.KEY_HEIGHT),
                format.optionalInteger(MediaFormat.KEY_CROP_LEFT),
                format.optionalInteger(MediaFormat.KEY_CROP_RIGHT),
                format.optionalInteger(MediaFormat.KEY_CROP_TOP),
                format.optionalInteger(MediaFormat.KEY_CROP_BOTTOM),
            )
            if (dimensions == null) {
                codec.releaseOutputBuffer(index, false)
                failFromWorker("frame_rejected", "MediaCodec returned invalid output dimensions.")
                return@DecoderOutputPump
            }
            rendererVisibility.present { visible ->
                presentation.offer(index, visible && decoderRunning.get())
            }
            synchronized(lock) {
                framesDecoded++
                width = dimensions.first
                height = dimensions.second
            }
        },
    )
    try {
        while (decoderRunning.get()) {
            if (decoderResetRequested.compareAndSet(true, false)) {
                try {
                    presentation.clear()
                    codec.flush()
                    pendingDecoderFrame.clear()
                    synchronized(lock) { width = 0; height = 0 }
                    decoderRecoveryGate.resetForFlush()
                } catch (_: IllegalStateException) {
                    failFromWorker("decoder_failed", "MediaCodec reset failed.")
                    break
                }
            }
            // Output may finish asynchronously after the last input frame.
            // Poll it even while a static screen supplies no new access unit.
            rendererVisibility.present { visible ->
                presentation.resume(visible && decoderRunning.get())
            }
            if (!pump.step()) Thread.sleep(2)
        }
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
    } catch (_: IllegalStateException) {
        failFromWorker("decoder_failed", "MediaCodec stopped unexpectedly.")
    } catch (_: Exception) {
        failFromWorker("decoder_failed", "Android decoder worker failed.")
    } finally {
        // Output indices belong to the running codec and must be returned
        // before the owner acknowledges stop or releases that codec.
        try { presentation.clear() } catch (_: IllegalStateException) { }
        synchronized(lock) {
            if (Thread.currentThread() == decoderThread) decoderThread = null
            decoderStopAck?.countDown()
        }
    }
}

private fun AndroidMediaOwner.queueDecoderInput(
    codec: MediaCodec,
): Boolean {
    if (decoderRecoveryGate.hasPendingConfig && !queueDecoderConfig(codec)) return false
    val frame = pendingDecoderFrame.acquire { NativeMediaBridge.pullH264(token) } ?: return false
    if (frame.status != 0) {
        failFromWorker(statusCode(frame.status), "Native H.264 egress failed.")
        return false
    }
    if (frame.payload.isEmpty() || frame.width <= 0 || frame.height <= 0) {
        failFromWorker("frame_rejected", "Native decoder received an invalid frame.")
        return false
    }
    val accessUnit = H264AnnexB.analyze(frame.payload)
    if (accessUnit == null) {
        failFromWorker("frame_rejected", "Native decoder returned malformed AVC data.")
        return false
    }
    val keyframe = frame.keyframe && accessUnit.containsIdr
    when (decoderRecoveryGate.inspect(accessUnit, keyframe)) {
        H264DecoderFrameDecision.REJECTED -> {
            failFromWorker("frame_rejected", "Native decoder returned malformed H.264 CSD.")
            return false
        }
        H264DecoderFrameDecision.DROP_AND_REQUEST -> {
            pendingDecoderFrame.clear()
            val recoveryFailure = requestDecoderRecoveryKeyframe()
            if (recoveryFailure != null) {
                failFromWorker(recoveryFailure, "Native decoder could not request a recovery keyframe.")
            }
            return false
        }
        H264DecoderFrameDecision.WAIT_FOR_CSD -> return false
        H264DecoderFrameDecision.QUEUE -> Unit
    }
    // Keep the one pending frame under codec backpressure. Output is still
    // drained on the next pump step before this input is retried.
    val inputIndex = codec.dequeueInputBuffer(10_000)
    if (inputIndex < 0) return false
    val input = codec.getInputBuffer(inputIndex)
    if (input == null || accessUnit.annexB.size > input.remaining()) {
        failFromWorker("frame_rejected", "Encoded frame exceeds the decoder input buffer.")
        return false
    }
    input.clear()
    input.put(accessUnit.annexB)
    codec.queueInputBuffer(inputIndex, 0, accessUnit.annexB.size,
        timestamp90kToUs(frame.timestamp), if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
    pendingDecoderFrame.markQueued()
    decoderRecoveryGate.markFrameQueued(keyframe)
    return true
}

private fun MediaFormat.optionalInteger(key: String): Int? =
    if (containsKey(key)) getInteger(key) else null

private fun AndroidMediaOwner.queueDecoderConfig(codec: MediaCodec): Boolean {
    val config = decoderRecoveryGate.cache.codecConfig() ?: return true
    val inputIndex = codec.dequeueInputBuffer(10_000)
    if (inputIndex < 0) return false
    val input = codec.getInputBuffer(inputIndex)
    if (input == null || config.size > input.remaining()) {
        failFromWorker("frame_rejected", "H.264 CSD exceeds the decoder input buffer.")
        return false
    }
    input.clear()
    input.put(config)
    codec.queueInputBuffer(inputIndex, 0, config.size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
    decoderRecoveryGate.markConfigQueued()
    return true
}

private fun AndroidMediaOwner.requestDecoderRecoveryKeyframe(): String? {
    val status = NativeMediaBridge.requestKeyframe(token)
    return if (status == 0) null else statusCode(status)
}
