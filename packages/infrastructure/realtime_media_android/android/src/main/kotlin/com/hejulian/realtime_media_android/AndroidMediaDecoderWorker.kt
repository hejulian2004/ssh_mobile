package com.hejulian.realtime_media_android

import android.media.MediaCodec
import kotlin.math.max

/** Borrows one owner's decoder; the owner alone releases its resources. */
internal fun AndroidMediaOwner.drainDecoder() {
    val codec = synchronized(lock) { decoder } ?: return
    val info = MediaCodec.BufferInfo()
    var queuedWidth = 0
    var queuedHeight = 0
    val pump = DecoderOutputPump(
        isActive = { decoderRunning.get() },
        submitInput = {
            queueDecoderInput(codec) { nextWidth, nextHeight ->
                queuedWidth = nextWidth
                queuedHeight = nextHeight
            }
        },
        readOutput = { codec.dequeueOutputBuffer(info, 0) },
        renderOutput = { index ->
            codec.releaseOutputBuffer(index, true)
            synchronized(lock) {
                framesDecoded++
                framesRendered++
                width = max(width, queuedWidth)
                height = max(height, queuedHeight)
            }
        },
    )
    try {
        while (decoderRunning.get()) {
            if (decoderResetRequested.compareAndSet(true, false)) {
                try {
                    codec.flush()
                    pendingDecoderFrame.clear()
                    queuedWidth = 0
                    queuedHeight = 0
                    synchronized(lock) { width = 0; height = 0 }
                    decoderRecoveryGate.resetForFlush()
                } catch (_: IllegalStateException) {
                    failFromWorker("decoder_failed", "MediaCodec reset failed.")
                    break
                }
            }
            // Output may finish asynchronously after the last input frame.
            // Poll it even while a static screen supplies no new access unit.
            if (!pump.step()) Thread.sleep(2)
        }
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
    } catch (_: IllegalStateException) {
        failFromWorker("decoder_failed", "MediaCodec stopped unexpectedly.")
    } catch (_: Exception) {
        failFromWorker("decoder_failed", "Android decoder worker failed.")
    } finally {
        synchronized(lock) {
            if (Thread.currentThread() == decoderThread) decoderThread = null
            decoderStopAck?.countDown()
        }
    }
}

private fun AndroidMediaOwner.queueDecoderInput(
    codec: MediaCodec,
    onQueued: (Int, Int) -> Unit,
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
    onQueued(frame.width, frame.height)
    pendingDecoderFrame.markQueued()
    decoderRecoveryGate.markFrameQueued(keyframe)
    return true
}

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
