package com.hejulian.realtime_media_android

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodec
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.WindowManager
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch


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
    internal val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    internal var projectionLease: ProjectionLease? = null
    internal var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    internal var encoder: MediaCodec? = null
    internal var encoderSurface: Surface? = null
    internal var encoderThread: Thread? = null
    internal var encoderStopAck: CountDownLatch? = null
    internal var captureRunning = AtomicBoolean(false)
    internal var decoder: MediaCodec? = null
    internal var decoderSurface: Surface? = null
    internal var decoderThread: Thread? = null
    internal var decoderStopAck: CountDownLatch? = null
    internal var decoderRunning = AtomicBoolean(false)
    internal var decoderResetRequested = AtomicBoolean(false)
    internal var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    internal var width = 0
    internal var height = 0
    internal var sequence = 0L
    private var terminalCode: String? = null
    private var terminalMessage: String? = null
    internal var framesCaptured = 0L
    internal var framesSent = 0L
    internal var framesDecoded = 0L
    internal var framesRendered = 0L
    internal var framesDropped = 0L
    internal var targetFramerate = 30
    internal var targetBitrateKbps = 0
    internal var nextEncodeTimestamp90k = 0L
    internal var encoderRecoveryGate = H264EncoderRecoveryGate()
    internal var lastEncoderRecoveryRequestNanos = Long.MIN_VALUE
    internal val decoderRecoveryGate = H264DecoderRecoveryGate()
    internal val pendingDecoderFrame = PendingDecoderFrame<NativeH264Frame>()

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

    internal fun failFromWorker(code: String, message: String) {
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

    internal fun markCleanupDeferred(message: String) {
        synchronized(lock) {
            terminalCode = "cleanup_deferred"
            terminalMessage = message
        }
    }

    internal fun clearDeferredCleanup() {
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

    internal fun displaySize(): Pair<Int, Int> {
        val metrics = context.resources.displayMetrics
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = context.getSystemService(WindowManager::class.java)
            val bounds = manager?.currentWindowMetrics?.bounds
            if (bounds != null) return bounds.width() to bounds.height()
        }
        return metrics.widthPixels to metrics.heightPixels
    }

    internal fun statusCode(status: Int): String = when (status) {
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
