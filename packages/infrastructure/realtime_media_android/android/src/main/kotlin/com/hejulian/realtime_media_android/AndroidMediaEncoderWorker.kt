package com.hejulian.realtime_media_android

import android.media.MediaCodec
import android.media.MediaFormat
import java.nio.ByteBuffer

private const val MEDIA_FORMAT_CSD_0 = "csd-0"
private const val MEDIA_FORMAT_CSD_1 = "csd-1"

internal fun AndroidMediaOwner.drainEncoder() {
    val codec = synchronized(lock) { encoder } ?: return
    val info = MediaCodec.BufferInfo()
    try {
        while (captureRunning.get()) {
            val dimensions = displaySize()
            if (dimensions.first != width || dimensions.second != height) {
                failFromWorker("capture_source_ended", "Display resolution changed; restart the owner.")
                break
            }
            when (val index = codec.dequeueOutputBuffer(info, 10_000)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val format = codec.outputFormat
                    synchronized(lock) {
                        if (format.containsKey(MediaFormat.KEY_WIDTH)) {
                            width = format.getInteger(MediaFormat.KEY_WIDTH)
                        }
                        if (format.containsKey(MediaFormat.KEY_HEIGHT)) {
                            height = format.getInteger(MediaFormat.KEY_HEIGHT)
                        }
                    }
                    val csd0 = copyMediaFormatBuffer(format, MEDIA_FORMAT_CSD_0)
                    val csd1 = copyMediaFormatBuffer(format, MEDIA_FORMAT_CSD_1)
                    if (!encoderRecoveryGate.updateCodecConfig(csd0, csd1)) {
                        failFromWorker("frame_rejected", "MediaCodec returned malformed H.264 CSD.")
                        break
                    }
                }
                else -> if (index >= 0) {
                    try {
                        val buffer = codec.getOutputBuffer(index)
                        if (info.size > 0) {
                            if (buffer == null) {
                                failFromWorker("frame_rejected", "MediaCodec returned no output buffer.")
                                break
                            }
                            val payload = copyCodecBuffer(buffer, info)
                            if (payload == null) {
                                failFromWorker("frame_rejected", "MediaCodec returned malformed AVC data.")
                                break
                            }
                            val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            if (config) {
                                // Codec-config output belongs only in the
                                // bounded CSD cache. It is never a media
                                // access unit by itself.
                                if (!encoderRecoveryGate.updateCodecConfig(payload, null)) {
                                    failFromWorker("frame_rejected", "MediaCodec returned malformed H.264 CSD.")
                                    break
                                }
                            } else {
                                val accessUnit = H264AnnexB.analyze(payload)
                                if (accessUnit == null) {
                                    failFromWorker("frame_rejected", "MediaCodec returned malformed AVC data.")
                                    break
                                }
                                val keyframe =
                                    info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 &&
                                        accessUnit.containsIdr
                                val prepared = encoderRecoveryGate.prepare(accessUnit, keyframe)
                                if (prepared == null) {
                                    synchronized(lock) { framesDropped++ }
                                    val recoveryFailure = requestEncoderRecoveryKeyframe()
                                    if (recoveryFailure != null) {
                                        failFromWorker(
                                            recoveryFailure,
                                            "Android encoder could not request a recovery keyframe.",
                                        )
                                        break
                                    }
                                } else {
                                    val timestamp = timestampUsTo90k(info.presentationTimeUs)
                                    val shouldSend = synchronized(lock) {
                                        val interval = 90_000L / targetFramerate.coerceIn(5, 30)
                                        if (timestamp < nextEncodeTimestamp90k) {
                                            framesDropped++
                                            false
                                        } else {
                                            nextEncodeTimestamp90k =
                                                if (timestamp > Long.MAX_VALUE - interval) {
                                                    Long.MAX_VALUE
                                                } else {
                                                    timestamp + interval
                                                }
                                            true
                                        }
                                    }
                                    if (shouldSend) {
                                        val sequenceValue = synchronized(lock) { sequence++ }
                                        val status = NativeMediaBridge.pushH264(
                                            token,
                                            sequenceValue,
                                            timestamp,
                                            width,
                                            height,
                                            keyframe,
                                            prepared,
                                        )
                                        encoderRecoveryGate.onPushResult(keyframe, status)
                                        when {
                                            status == 0 -> synchronized(lock) {
                                                framesCaptured++
                                                framesSent++
                                                if (!encoderRecoveryGate.awaitingRecoveryKeyframe) {
                                                    lastEncoderRecoveryRequestNanos = Long.MIN_VALUE
                                                }
                                            }
                                            status == NativeMediaBridge.FRAME_DROPPED -> {
                                                synchronized(lock) { framesCaptured++ }
                                                // Keep the CSD+IDR gate closed;
                                                // the native request path is
                                                // rate-limited/coalesced.
                                                val recoveryFailure = requestEncoderRecoveryKeyframe()
                                                if (recoveryFailure != null) {
                                                    failFromWorker(
                                                        recoveryFailure,
                                                        "Android encoder could not request a recovery keyframe.",
                                                    )
                                                    break
                                                }
                                            }
                                            else -> {
                                                failFromWorker(
                                                    statusCode(status),
                                                    "Native H.264 ingress rejected the frame.",
                                                )
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } finally {
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            }
        }
    } catch (_: IllegalStateException) {
        failFromWorker("encoder_failed", "MediaCodec stopped unexpectedly.")
    } catch (_: Exception) {
        failFromWorker("encoder_failed", "Android encoder worker failed.")
    } finally {
        synchronized(lock) {
            if (Thread.currentThread() == encoderThread) encoderThread = null
            encoderStopAck?.countDown()
        }
    }
}

internal fun AndroidMediaOwner.requestEncoderRecoveryKeyframe(): String? {
    val now = System.nanoTime()
    synchronized(lock) {
        if (lastEncoderRecoveryRequestNanos != Long.MIN_VALUE &&
            now - lastEncoderRecoveryRequestNanos < 1_000_000_000L
        ) {
            return null
        }
        lastEncoderRecoveryRequestNanos = now
    }
    return requestKeyframe()
}

internal fun AndroidMediaOwner.copyCodecBuffer(buffer: ByteBuffer, info: MediaCodec.BufferInfo): ByteArray? {
    if (info.offset < 0 || info.size <= 0 || info.offset > buffer.capacity() - info.size) {
        return null
    }
    return try {
        val duplicate = buffer.duplicate()
        duplicate.position(info.offset)
        duplicate.limit(info.offset + info.size)
        ByteArray(info.size).also { duplicate.get(it) }
    } catch (_: IllegalArgumentException) {
        null
    }
}

internal fun AndroidMediaOwner.copyMediaFormatBuffer(format: MediaFormat, key: String): ByteArray? {
    if (!format.containsKey(key)) return null
    val buffer = format.getByteBuffer(key) ?: return null
    return try {
        val duplicate = buffer.duplicate()
        ByteArray(duplicate.remaining()).also { duplicate.get(it) }
    } catch (_: IllegalArgumentException) {
        null
    }
}
