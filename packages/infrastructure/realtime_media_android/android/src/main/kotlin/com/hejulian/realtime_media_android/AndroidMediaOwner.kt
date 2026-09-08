package com.hejulian.realtime_media_android

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.WindowManager
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

internal data class AndroidOwnerIdentity(
    val endpointId: String,
    val realtimeId: String,
    val peerId: String,
    val generation: Long,
    val direction: String,
)

internal class AndroidMediaOwner(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    val token: Long,
    val identity: AndroidOwnerIdentity,
) {
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var encoderThread: Thread? = null
    private var captureRunning = AtomicBoolean(false)
    private var decoder: MediaCodec? = null
    private var decoderSurface: Surface? = null
    private var decoderThread: Thread? = null
    private var decoderRunning = AtomicBoolean(false)
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

    fun startCapture(mediaProjection: MediaProjection?, sourceId: String): String? {
        synchronized(lock) {
            if (identity.direction != "send") return "direction_mismatch"
            if (captureRunning.get()) return "duplicate_endpoint"
            if (sourceId != "display:default") return "capture_source_ended"
            if (mediaProjection == null) return "permission_denied"
            if (terminalCode != null) return terminalCode
            val dimensions = displaySize()
            if (dimensions.first <= 0 || dimensions.second <= 0) return "capture_source_ended"
            val startStatus = NativeMediaBridge.startOwner(token)
            if (startStatus != 0) return statusCode(startStatus)
            width = dimensions.first
            height = dimensions.second
            val codec = AndroidCodecFactory.createEncoder(width, height)
                ?: return stopNativeAfterFailure("encoder_unavailable")
            try {
                val input = codec.createInputSurface()
                codec.start()
                encoder = codec
                encoderSurface = input
                projection = mediaProjection
                virtualDisplay = mediaProjection.createVirtualDisplay(
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
            if (decoderRunning.get() || textureEntry != null) return "duplicate_endpoint"
            if (terminalCode != null) return terminalCode
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
        stopCapture()
        stopDecoder()
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

    fun release(): String? {
        val detachFailure = detach()
        var failure = detachFailure?.takeUnless(::isTerminalReleaseFailure)
        val stopStatus = NativeMediaBridge.stopOwner(token)
        if (failure == null && stopStatus != 0 && stopStatus != -12) {
            failure = statusCode(stopStatus)
        }
        val closeStatus = NativeMediaBridge.closeOwner(token)
        if (failure == null && closeStatus != 0 && closeStatus != -12) {
            failure = statusCode(closeStatus)
        }
        // Always attempt stop/close after local resources are quiesced. A
        // transient detach/driver error is still returned to the caller, but
        // closing the owner prevents a plugin detach from leaking the native
        // registry; a retry then receives the idempotent stale-owner result.
        return failure
    }

    fun onProjectionRevoked() {
        synchronized(lock) {
            terminalCode = "projection_revoked"
            terminalMessage = "MediaProjection was revoked by the system."
        }
        stopCapture()
    }

    fun stats(): Map<String, Any> = synchronized(lock) {
        mapOf(
            "width" to width,
            "height" to height,
            "frames_captured" to framesCaptured,
            "frames_sent" to framesSent,
            "frames_dropped" to framesDropped,
            "frames_decoded" to framesDecoded,
            "frames_rendered" to framesRendered,
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
                    }
                    else -> if (index >= 0) {
                        try {
                            val buffer = codec.getOutputBuffer(index)
                            val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            if (buffer != null && info.size > 0 && !config) {
                                val payload = ByteArray(info.size)
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.get(payload)
                                val annexB = H264AnnexB.normalize(payload)
                                if (annexB == null) {
                                    failFromWorker("frame_rejected", "MediaCodec returned malformed AVC data.")
                                    break
                                }
                                val timestamp = timestampUsTo90k(info.presentationTimeUs)
                                val sequenceValue = synchronized(lock) { sequence++ }
                                val status = NativeMediaBridge.pushH264(
                                    token,
                                    sequenceValue,
                                    timestamp,
                                    width,
                                    height,
                                    info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0,
                                    annexB,
                                )
                                when {
                                    status == 0 -> synchronized(lock) {
                                        framesCaptured++
                                        framesSent++
                                    }
                                    status == 1 -> synchronized(lock) {
                                        framesCaptured++
                                        framesDropped++
                                    }
                                    else -> {
                                        failFromWorker(statusCode(status), "Native H.264 ingress rejected the frame.")
                                        break
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
        } finally {
            synchronized(lock) {
                if (Thread.currentThread() == encoderThread) encoderThread = null
            }
            releaseEncoderResources()
        }
    }

    private fun drainDecoder() {
        val codec = synchronized(lock) { decoder } ?: return
        val info = MediaCodec.BufferInfo()
        try {
            while (decoderRunning.get()) {
                val frame = NativeMediaBridge.pullH264(token)
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
                val inputIndex = codec.dequeueInputBuffer(10_000)
                if (inputIndex >= 0) {
                    val input = codec.getInputBuffer(inputIndex)
                    if (input == null || frame.payload.size > input.remaining()) {
                        failFromWorker("frame_rejected", "Encoded frame exceeds the decoder input buffer.")
                        break
                    }
                    input.clear()
                    input.put(frame.payload)
                    codec.queueInputBuffer(
                        inputIndex,
                        0,
                        frame.payload.size,
                        timestamp90kToUs(frame.timestamp),
                        if (frame.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
                    )
                }
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
        } finally {
            synchronized(lock) {
                if (Thread.currentThread() == decoderThread) decoderThread = null
            }
            releaseDecoderResources()
        }
    }

    private fun stopCapture() {
        val thread = synchronized(lock) {
            captureRunning.set(false)
            encoderThread
        }
        if (thread != null && thread !== Thread.currentThread()) {
            thread.interrupt()
            try {
                thread.join(2_000)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        releaseEncoderResources()
        NativeMediaBridge.stopOwner(token)
    }

    private fun stopDecoder() {
        val thread = synchronized(lock) {
            decoderRunning.set(false)
            decoderThread
        }
        if (thread != null && thread !== Thread.currentThread()) {
            thread.interrupt()
            try {
                thread.join(2_000)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        releaseDecoderResources()
    }

    private fun releaseEncoderResources() {
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
            projection = null
            encoderThread = null
        }
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
            decoderThread = null
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

    private fun stopNativeAfterFailure(code: String): String {
        terminalCode = code
        terminalMessage = "Android media owner could not start."
        NativeMediaBridge.stopOwner(token)
        return code
    }

    private fun isTerminalReleaseFailure(code: String): Boolean =
        code == "stale_endpoint" || code == "session_released" ||
            code == "stale_owner"

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
