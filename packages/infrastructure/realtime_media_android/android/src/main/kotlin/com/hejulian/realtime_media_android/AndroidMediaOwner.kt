package com.hejulian.realtime_media_android

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.WindowManager
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.max

private const val MEDIA_FORMAT_CSD_0 = "csd-0"
private const val MEDIA_FORMAT_CSD_1 = "csd-1"

internal data class AndroidOwnerIdentity(
    val endpointId: String,
    val realtimeId: String,
    val peerId: String,
    val generation: Long,
    val direction: String,
)

internal data class AndroidMediaStatsSnapshot(
    val failure: String? = null,
    val values: Map<String, Any> = emptyMap(),
)

internal class AndroidMediaOwner(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    val token: Long,
    val identity: AndroidOwnerIdentity,
) {
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var projectionLease: ProjectionLease? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var encoderThread: Thread? = null
    private var encoderStopAck: CountDownLatch? = null
    private var captureRunning = AtomicBoolean(false)
    private var decoder: MediaCodec? = null
    private var decoderSurface: Surface? = null
    private var decoderThread: Thread? = null
    private var decoderStopAck: CountDownLatch? = null
    private var decoderRunning = AtomicBoolean(false)
    private var decoderResetRequested = AtomicBoolean(false)
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var width = 0
    private var height = 0
    private var sequence = 0L
    private var terminalCode: String? = null
    private var terminalMessage: String? = null
    private var framesCaptured = 0L
    private var framesSent = 0L
    private var framesDecoded = 0L
    private var framesRendered = 0L
    private var framesDropped = 0L
    private var targetFramerate = 30
    private var targetBitrateKbps = 0
    private var nextEncodeTimestamp90k = 0L
    private var encoderRecoveryGate = H264EncoderRecoveryGate()
    private var lastEncoderRecoveryRequestNanos = Long.MIN_VALUE
    private val decoderRecoveryGate = H264DecoderRecoveryGate()
    private val pendingDecoderFrame = PendingDecoderFrame<NativeH264Frame>()

    fun startCapture(
        projectionLease: ProjectionLease?,
        sourceId: String,
        sourceKind: String,
    ): String? {
        synchronized(lock) {
            if (identity.direction != "send") return "direction_mismatch"
            if (captureRunning.get() || encoderThread != null || encoder != null ||
                virtualDisplay != null || encoderSurface != null
            ) {
                // A timed-out worker remains the owner of its codec/surface.
                // Never start a replacement capture until the previous worker
                // has acknowledged termination and resources were released.
                return if (terminalCode == "cleanup_deferred") {
                    "cleanup_deferred"
                } else {
                    "duplicate_endpoint"
                }
            }
            if (sourceKind != "display" || sourceId != "display:default") {
                return "capture_source_ended"
            }
            val lease = projectionLease ?: return "permission_denied"
            if (terminalCode != null) return terminalCode
            val dimensions = displaySize()
            if (dimensions.first <= 0 || dimensions.second <= 0) return "capture_source_ended"
            if (!lease.consume(token)) return "duplicate_endpoint"
            this.projectionLease = lease
            encoderRecoveryGate = H264EncoderRecoveryGate()
            lastEncoderRecoveryRequestNanos = Long.MIN_VALUE
            val startStatus = NativeMediaBridge.startOwner(token)
            if (startStatus != 0) {
                this.projectionLease = null
                lease.releaseAfterResources()
                return statusCode(startStatus)
            }
            width = dimensions.first
            height = dimensions.second
            targetBitrateKbps = AndroidCodecFactory.initialBitrateKbps(width, height)
            val codec = AndroidCodecFactory.createEncoder(width, height)
                ?: return stopNativeAfterFailure("encoder_unavailable")
            try {
                // Publish the codec and input surface to the owner before any
                // subsequent start/configuration step can fail. The catch
                // path then releases exactly the resources acquired here.
                encoder = codec
                val input = codec.createInputSurface()
                encoderSurface = input
                codec.start()
                virtualDisplay = lease.mediaProjection.createVirtualDisplay(
                    "ssh-mobile-screen-share",
                    width,
                    height,
                    context.resources.displayMetrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    input,
                    null,
                    mainHandler,
                ) ?: throw IllegalStateException("MediaProjection returned no display")
                captureRunning.set(true)
                encoderStopAck = CountDownLatch(1)
                encoderThread = Thread({ drainEncoder() }, "realtime-media-android-encoder").also {
                    it.isDaemon = true
                    it.start()
                }
                return null
            } catch (_: SecurityException) {
                releaseEncoderResources()
                return stopNativeAfterFailure("permission_denied")
            } catch (_: Exception) {
                releaseEncoderResources()
                return stopNativeAfterFailure("encoder_unavailable")
            }
        }
    }

    fun attachDecoder(): String? {
        synchronized(lock) {
            if (identity.direction != "receive") return "direction_mismatch"
            if (decoderRunning.get() || decoderThread != null || decoder != null ||
                decoderSurface != null || textureEntry != null
            ) {
                return if (terminalCode == "cleanup_deferred") {
                    "cleanup_deferred"
                } else {
                    "duplicate_endpoint"
                }
            }
            if (terminalCode != null) return terminalCode
            decoderRecoveryGate.clear()
            pendingDecoderFrame.clear()
            val validation = NativeMediaBridge.validateOwner(token)
            if (validation != 0) return statusCode(validation)
            val startStatus = NativeMediaBridge.startOwner(token)
            if (startStatus != 0) return statusCode(startStatus)
            val rendererStatus = NativeMediaBridge.attachRenderer(token)
            if (rendererStatus != 0) {
                NativeMediaBridge.stopOwner(token)
                return statusCode(rendererStatus)
            }
            val entry = textureRegistry.createSurfaceTexture()
            val surfaceTexture = entry.surfaceTexture()
            surfaceTexture.setDefaultBufferSize(16, 16)
            val surface = Surface(surfaceTexture)
            val codec = AndroidCodecFactory.createDecoder(16, 16, surface)
            if (codec == null) {
                surface.release()
                entry.release()
                NativeMediaBridge.detachRenderer(token)
                NativeMediaBridge.stopOwner(token)
                return "decoder_unavailable"
            }
            try {
                codec.start()
                textureEntry = entry
                decoderSurface = surface
                decoder = codec
                decoderRunning.set(true)
                decoderStopAck = CountDownLatch(1)
                decoderThread = Thread({ drainDecoder() }, "realtime-media-android-decoder").also {
                    it.isDaemon = true
                    it.start()
                }
                return null
            } catch (_: Exception) {
                try {
                    codec.release()
                } catch (_: Exception) {
                    // Codec failure is already terminal for this attach.
                }
                surface.release()
                entry.release()
                NativeMediaBridge.detachRenderer(token)
                NativeMediaBridge.stopOwner(token)
                return "decoder_unavailable"
            }
        }
    }

    fun surfaceId(): String? = synchronized(lock) { textureEntry?.id()?.toString() }

    fun detach(): String? {
        val captureFailure = stopCapture()
        if (captureFailure != null) return captureFailure
        val decoderFailure = stopDecoder()
        if (decoderFailure != null) return decoderFailure
        // A send owner has no renderer capability. The native ABI correctly
        // reports direction mismatch for detachRenderer on that path, so
        // only detach a renderer that was attached to a receive owner.
        val status = if (identity.direction == "receive") {
            NativeMediaBridge.detachRenderer(token)
        } else {
            0
        }
        return if (status == 0 || status == -12) null else statusCode(status)
    }

    fun requestKeyframe(): String? {
        synchronized(lock) {
            val status = NativeMediaBridge.requestKeyframe(token)
            if (status != 0) return statusCode(status)
            if (identity.direction != "send") return null
            val codec = encoder ?: return "encoder_unavailable"
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.KITKAT) {
                return "encoder_unavailable"
            }
            return try {
                codec.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
                null
            } catch (_: IllegalStateException) {
                terminalCode = "encoder_failed"
                terminalMessage = "MediaCodec rejected the keyframe request."
                "encoder_failed"
            } catch (_: UnsupportedOperationException) {
                "encoder_unavailable"
            }
        }
    }

    fun resetDecoder(): String? {
        synchronized(lock) {
            if (identity.direction != "receive") return "direction_mismatch"
            if (terminalCode != null) return terminalCode
            val status = NativeMediaBridge.resetDecoder(token)
            if (status != 0) return statusCode(status)
            if (decoder == null || !decoderRunning.get()) return "decoder_unavailable"
            decoderResetRequested.set(true)
            return null
        }
    }

    fun applyAdaptation(
        bitrateKbps: Int,
        framerate: Int,
        targetWidth: Int,
        targetHeight: Int,
        reason: Int,
    ): String? {
        synchronized(lock) {
            if (identity.direction != "send") return "direction_mismatch"
            if (bitrateKbps !in 256..(3 * 1024) || framerate !in 5..30 ||
                targetWidth < 0 || targetHeight < 0 ||
                ((targetWidth == 0) != (targetHeight == 0)) ||
                reason !in 0..2
            ) return "invalid_argument"
            if (terminalCode != null) return terminalCode
            val codec = encoder ?: return "encoder_unavailable"
            if (targetWidth != 0 &&
                (targetWidth != width || targetHeight != height)
            ) {
                // Resolution changes require stop/release/recreate so a stale
                // surface or capture callback cannot survive an in-place swap.
                return "encoder_failed"
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.KITKAT) {
                return "encoder_unavailable"
            }
            val previousBitrateKbps = targetBitrateKbps
            val previousFramerate = targetFramerate
            val platformFailure = setEncoderBitrate(codec, bitrateKbps)
            if (platformFailure != null) {
                terminalCode = if (platformFailure == "encoder_failed") {
                    "encoder_failed"
                } else {
                    platformFailure
                }
                terminalMessage = "MediaCodec rejected the adaptation target."
                return platformFailure
            }
            val nativeStatus = NativeMediaBridge.applyAdaptation(
                token,
                bitrateKbps,
                framerate,
                targetWidth,
                targetHeight,
                reason,
            )
            if (nativeStatus != 0) {
                val rollbackFailure = setEncoderBitrate(codec, previousBitrateKbps)
                if (rollbackFailure != null) {
                    markAdaptationRecreateRequired(
                        "Native adaptation commit failed and encoder rollback failed.",
                    )
                    return "recreate_required"
                }
                // The native owner rejected the target before committing it;
                // the platform target is restored to the same previous value.
                // Do not publish a partially applied target or poison the
                // owner for a retryable stale/native failure.
                return statusCode(nativeStatus)
            }
            targetBitrateKbps = bitrateKbps
            targetFramerate = framerate
            nextEncodeTimestamp90k = 0L
            return null
        }
    }

    fun release(): String? {
        val detachFailure = detach()
        if (detachFailure != null) return detachFailure
        val nativeStatus = releaseNativeOwner(
            stopOwner = { NativeMediaBridge.stopOwner(token) },
            closeOwner = { NativeMediaBridge.closeOwner(token) },
        )
        return if (nativeStatus == 0) null else statusCode(nativeStatus)
    }

    fun onProjectionRevoked() {
        synchronized(lock) {
            terminalCode = "projection_revoked"
            terminalMessage = "MediaProjection was revoked by the system."
        }
        stopCapture()
    }

    fun isCaptureOwnerActive(): Boolean = synchronized(lock) {
        identity.direction == "send" &&
            (captureRunning.get() || encoderThread != null || virtualDisplay != null)
    }

    fun stats(): AndroidMediaStatsSnapshot = synchronized(lock) {
        val native = NativeMediaBridge.readStats(token)
        if (native.status != 0) {
            return@synchronized AndroidMediaStatsSnapshot(
                failure = statusCode(native.status),
            )
        }
        if (native.queueCapacity != 3 || native.queueDepth !in 0..3) {
            return@synchronized AndroidMediaStatsSnapshot(
                failure = "backend_failure",
            )
        }
        AndroidMediaStatsSnapshot(
            values = mapOf(
                "width" to width,
                "height" to height,
                "frames_captured" to framesCaptured,
                "frames_sent" to framesSent,
                "frames_dropped" to (framesDropped + native.dropped),
                "frames_decoded" to framesDecoded,
                "frames_rendered" to framesRendered,
                "packets_sent" to native.packetsSent,
                "packets_received" to native.packetsReceived,
                "packets_lost" to native.packetsLost,
                "frames_recovered" to native.framesRecovered,
                "keyframe_requests" to native.keyframeRequests,
                "jitter_ms" to native.jitterMs,
                "rtt_ms" to native.rttMs,
                "queue_depth" to native.queueDepth,
                "queue_capacity" to native.queueCapacity,
            ),
        )
    }

    fun terminalFailure(): Pair<String, String>? = synchronized(lock) {
        val code = terminalCode ?: return@synchronized null
        code to (terminalMessage ?: "Android media owner failed.")
    }

    private fun drainEncoder() {
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

    private fun requestEncoderRecoveryKeyframe(): String? {
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

    private fun copyCodecBuffer(buffer: ByteBuffer, info: MediaCodec.BufferInfo): ByteArray? {
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

    private fun copyMediaFormatBuffer(format: MediaFormat, key: String): ByteArray? {
        if (!format.containsKey(key)) return null
        val buffer = format.getByteBuffer(key) ?: return null
        return try {
            val duplicate = buffer.duplicate()
            ByteArray(duplicate.remaining()).also { duplicate.get(it) }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun drainDecoder() {
        val codec = synchronized(lock) { decoder } ?: return
        val info = MediaCodec.BufferInfo()
        try {
            while (decoderRunning.get()) {
                if (decoderResetRequested.compareAndSet(true, false)) {
                    try {
                        codec.flush()
                        pendingDecoderFrame.clear()
                        synchronized(lock) {
                            width = 0
                            height = 0
                        }
                        decoderRecoveryGate.resetForFlush()
                    } catch (_: IllegalStateException) {
                        failFromWorker("decoder_failed", "MediaCodec reset failed.")
                        break
                    }
                }

                if (decoderRecoveryGate.hasPendingConfig && !queueDecoderConfig(codec)) {
                    Thread.sleep(2)
                    continue
                }

                val frame = pendingDecoderFrame.acquire {
                    NativeMediaBridge.pullH264(token)
                }
                if (frame == null) {
                    Thread.sleep(2)
                    continue
                }
                if (frame.status != 0) {
                    failFromWorker(statusCode(frame.status), "Native H.264 egress failed.")
                    break
                }
                if (frame.payload.isEmpty() || frame.width <= 0 || frame.height <= 0) {
                    failFromWorker("frame_rejected", "Native decoder received an invalid frame.")
                    break
                }
                val accessUnit = H264AnnexB.analyze(frame.payload)
                if (accessUnit == null) {
                    failFromWorker("frame_rejected", "Native decoder returned malformed AVC data.")
                    break
                }
                val keyframe = frame.keyframe && accessUnit.containsIdr
                when (decoderRecoveryGate.inspect(accessUnit, keyframe)) {
                    H264DecoderFrameDecision.REJECTED -> {
                        failFromWorker("frame_rejected", "Native decoder returned malformed H.264 CSD.")
                        break
                    }
                    H264DecoderFrameDecision.DROP_AND_REQUEST -> {
                        pendingDecoderFrame.clear()
                        val recoveryFailure = requestDecoderRecoveryKeyframe()
                        if (recoveryFailure != null) {
                            failFromWorker(
                                recoveryFailure,
                                "Native decoder could not request a recovery keyframe.",
                            )
                            break
                        }
                        continue
                    }
                    H264DecoderFrameDecision.WAIT_FOR_CSD -> {
                        // Keep this frame retained while the cached or newly
                        // received CSD is replayed before its access unit.
                        continue
                    }
                    H264DecoderFrameDecision.QUEUE -> Unit
                }
                val inputIndex = codec.dequeueInputBuffer(10_000)
                if (inputIndex < 0) {
                    // The native frame has already been popped, so retain it
                    // locally and retry the same frame rather than silently
                    // losing a keyframe under codec backpressure.
                    Thread.sleep(2)
                    continue
                }
                val input = codec.getInputBuffer(inputIndex)
                if (input == null || accessUnit.annexB.size > input.remaining()) {
                    failFromWorker("frame_rejected", "Encoded frame exceeds the decoder input buffer.")
                    break
                }
                input.clear()
                input.put(accessUnit.annexB)
                codec.queueInputBuffer(
                    inputIndex,
                    0,
                    accessUnit.annexB.size,
                    timestamp90kToUs(frame.timestamp),
                    if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                )
                pendingDecoderFrame.markQueued()
                decoderRecoveryGate.markFrameQueued(keyframe)
                var outputIndex = codec.dequeueOutputBuffer(info, 0)
                while (outputIndex >= 0) {
                    codec.releaseOutputBuffer(outputIndex, true)
                    synchronized(lock) {
                        framesDecoded++
                        framesRendered++
                        width = max(width, frame.width)
                        height = max(height, frame.height)
                    }
                    outputIndex = codec.dequeueOutputBuffer(info, 0)
                }
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

    private fun queueDecoderConfig(codec: MediaCodec): Boolean {
        val config = decoderRecoveryGate.cache.codecConfig()
        if (config == null) {
            return true
        }
        val inputIndex = codec.dequeueInputBuffer(10_000)
        if (inputIndex < 0) return false
        val input = codec.getInputBuffer(inputIndex)
        if (input == null || config.size > input.remaining()) {
            failFromWorker("frame_rejected", "H.264 CSD exceeds the decoder input buffer.")
            return false
        }
        input.clear()
        input.put(config)
        codec.queueInputBuffer(
            inputIndex,
            0,
            config.size,
            0,
            MediaCodec.BUFFER_FLAG_CODEC_CONFIG,
        )
        decoderRecoveryGate.markConfigQueued()
        return true
    }

    private fun requestDecoderRecoveryKeyframe(): String? {
        val status = NativeMediaBridge.requestKeyframe(token)
        return if (status == 0) null else statusCode(status)
    }

    private fun stopCapture(): String? {
        if (identity.direction != "send") return null
        val worker = synchronized(lock) {
            captureRunning.set(false)
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

    private fun stopDecoder(): String? {
        if (identity.direction != "receive") return null
        val worker = synchronized(lock) {
            decoderRunning.set(false)
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

    private fun releaseEncoderResources() {
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

    private fun releaseDecoderResources() {
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
            textureEntry?.release()
            textureEntry = null
            pendingDecoderFrame.clear()
            decoderThread = null
            decoderStopAck = null
        }
    }

    private fun failFromWorker(code: String, message: String) {
        synchronized(lock) {
            terminalCode = code
            terminalMessage = message
            if (code.startsWith("encoder") || code == "frame_rejected") {
                framesDropped++
            }
            captureRunning.set(false)
            decoderRunning.set(false)
        }
    }

    private fun markCleanupDeferred(message: String) {
        synchronized(lock) {
            terminalCode = "cleanup_deferred"
            terminalMessage = message
        }
    }

    private fun clearDeferredCleanup() {
        synchronized(lock) {
            if (terminalCode == "cleanup_deferred") {
                terminalCode = null
                terminalMessage = null
            }
        }
    }

    private fun stopNativeAfterFailure(code: String): String {
        terminalCode = code
        terminalMessage = "Android media owner could not start."
        val lease = projectionLease
        projectionLease = null
        lease?.releaseAfterResources()
        NativeMediaBridge.stopOwner(token)
        return code
    }

    private fun setEncoderBitrate(codec: MediaCodec, bitrateKbps: Int): String? = try {
        codec.setParameters(Bundle().apply {
            putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrateKbps * 1_000)
        })
        null
    } catch (_: IllegalStateException) {
        "encoder_failed"
    } catch (_: UnsupportedOperationException) {
        "encoder_unavailable"
    }

    private fun markAdaptationRecreateRequired(message: String) {
        terminalCode = "recreate_required"
        terminalMessage = message
        captureRunning.set(false)
    }

    private fun displaySize(): Pair<Int, Int> {
        val metrics = context.resources.displayMetrics
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = context.getSystemService(WindowManager::class.java)
            val bounds = manager?.currentWindowMetrics?.bounds
            if (bounds != null) return bounds.width() to bounds.height()
        }
        return metrics.widthPixels to metrics.heightPixels
    }

    private fun statusCode(status: Int): String = when (status) {
        -1 -> "invalid_argument"
        -2 -> "unknown_session"
        -3 -> "backend_failure"
        -4 -> "session_released"
        -5 -> "stale_generation"
        -6 -> "stale_endpoint"
        -7 -> "direction_mismatch"
        -8 -> "duplicate_endpoint"
        -9 -> "driver_unavailable"
        -10 -> "peer_mismatch"
        -11 -> "frame_rejected"
        -12 -> "stale_owner"
        else -> "backend_failure"
    }
}
