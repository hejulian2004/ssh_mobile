package com.hejulian.realtime_media_android

/** A native-owned encoded H.264 access unit returned to the decoder worker. */
internal data class NativeH264Frame(
    val status: Int,
    val sequence: Long,
    val timestamp: Long,
    val width: Int,
    val height: Int,
    val keyframe: Boolean,
    val payload: ByteArray,
)

/** Bounded payload-free native queue/recovery counters for one owner. */
internal data class NativeMediaStats(
    val status: Int,
    val enqueued: Long,
    val dequeued: Long,
    val dropped: Long,
    val keyframeRequests: Long,
    val queueDepth: Int,
    val queueCapacity: Int,
)

/**
 * JNI facade for the native-only owner-token port.
 *
 * The library is loaded opportunistically because Flutter native assets may be
 * loaded after a platform plugin. Every wrapper remains fail-closed until the
 * bridge is available; no method reports synthetic media success.
 */
internal object NativeMediaBridge {
    private const val STATUS_DRIVER_UNAVAILABLE = -9
    private var loaded = false

    init {
        ensureLoaded()
    }

    fun validateOwner(owner: Long): Int = invoke { nativeValidateOwner(owner) }

    fun startOwner(owner: Long): Int = invoke { nativeStartOwner(owner) }

    fun stopOwner(owner: Long): Int = invoke { nativeStopOwner(owner) }

    fun attachRenderer(owner: Long): Int = invoke { nativeAttachRenderer(owner) }

    fun detachRenderer(owner: Long): Int = invoke { nativeDetachRenderer(owner) }

    fun requestKeyframe(owner: Long): Int = invoke { nativeRequestKeyframe(owner) }

    fun resetDecoder(owner: Long): Int = invoke { nativeResetDecoder(owner) }

    fun readStats(owner: Long): NativeMediaStats {
        val values = if (!ensureLoaded()) {
            null
        } else {
            try {
                nativeReadStats(owner)
            } catch (_: UnsatisfiedLinkError) {
                null
            }
        }
        if (values == null || values.size < 7) {
            return NativeMediaStats(STATUS_DRIVER_UNAVAILABLE, 0, 0, 0, 0, 0, 3)
        }
        return NativeMediaStats(
            status = values[0].coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt(),
            enqueued = values[1].coerceAtLeast(0),
            dequeued = values[2].coerceAtLeast(0),
            dropped = values[3].coerceAtLeast(0),
            keyframeRequests = values[4].coerceAtLeast(0),
            queueDepth = values[5].coerceIn(0, Int.MAX_VALUE.toLong()).toInt(),
            queueCapacity = values[6].coerceIn(0, Int.MAX_VALUE.toLong()).toInt(),
        )
    }

    fun applyAdaptation(
        owner: Long,
        bitrateKbps: Int,
        framerate: Int,
        width: Int,
        height: Int,
        reason: Int,
    ): Int = invoke {
        nativeApplyAdaptation(owner, bitrateKbps, framerate, width, height, reason)
    }

    fun closeOwner(owner: Long): Int = invoke { nativeCloseOwner(owner) }

    fun pushH264(
        owner: Long,
        sequence: Long,
        timestamp: Long,
        width: Int,
        height: Int,
        keyframe: Boolean,
        payload: ByteArray,
    ): Int =
        if (!ensureLoaded()) {
            STATUS_DRIVER_UNAVAILABLE
        } else {
            try {
                nativePushH264(owner, sequence, timestamp, width, height, keyframe, payload)
            } catch (_: UnsatisfiedLinkError) {
                STATUS_DRIVER_UNAVAILABLE
            }
        }

    fun pullH264(owner: Long): NativeH264Frame? =
        if (!ensureLoaded()) {
            NativeH264Frame(STATUS_DRIVER_UNAVAILABLE, 0, 0, 0, 0, false, ByteArray(0))
        } else {
            try {
                nativePullH264(owner)
            } catch (_: UnsatisfiedLinkError) {
                NativeH264Frame(STATUS_DRIVER_UNAVAILABLE, 0, 0, 0, 0, false, ByteArray(0))
            }
        }

    private inline fun invoke(call: () -> Int): Int =
        if (!ensureLoaded()) {
            STATUS_DRIVER_UNAVAILABLE
        } else {
            try {
                call()
            } catch (_: UnsatisfiedLinkError) {
                STATUS_DRIVER_UNAVAILABLE
            }
        }

    @Synchronized
    private fun ensureLoaded(): Boolean {
        if (loaded) return true
        return try {
            System.loadLibrary("realtime_media_android")
            loaded = true
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    @JvmStatic
    private external fun nativeValidateOwner(owner: Long): Int

    @JvmStatic
    private external fun nativeStartOwner(owner: Long): Int

    @JvmStatic
    private external fun nativeStopOwner(owner: Long): Int

    @JvmStatic
    private external fun nativeAttachRenderer(owner: Long): Int

    @JvmStatic
    private external fun nativeDetachRenderer(owner: Long): Int

    @JvmStatic
    private external fun nativeRequestKeyframe(owner: Long): Int

    @JvmStatic
    private external fun nativeResetDecoder(owner: Long): Int

    @JvmStatic
    private external fun nativeReadStats(owner: Long): LongArray?

    @JvmStatic
    private external fun nativeApplyAdaptation(
        owner: Long,
        bitrateKbps: Int,
        framerate: Int,
        width: Int,
        height: Int,
        reason: Int,
    ): Int

    @JvmStatic
    private external fun nativeCloseOwner(owner: Long): Int

    @JvmStatic
    private external fun nativePushH264(
        owner: Long,
        sequence: Long,
        timestamp: Long,
        width: Int,
        height: Int,
        keyframe: Boolean,
        payload: ByteArray,
    ): Int

    @JvmStatic
    private external fun nativePullH264(owner: Long): NativeH264Frame?
}
