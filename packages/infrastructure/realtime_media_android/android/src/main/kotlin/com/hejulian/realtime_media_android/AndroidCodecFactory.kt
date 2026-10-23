package com.hejulian.realtime_media_android

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

internal enum class AndroidCodecMode { AUTO, HARDWARE, CPU }

/** Explicit, request-scoped native H.264 selection. */
internal object AndroidCodecFactory {
    private const val MIME_AVC = "video/avc"
    private val requestMode = ThreadLocal<AndroidCodecMode>()

    fun parseCodecMode(value: Any?): AndroidCodecMode? = when (value) {
        null, "automatic" -> AndroidCodecMode.AUTO
        "hardware" -> AndroidCodecMode.HARDWARE
        "cpu" -> AndroidCodecMode.CPU
        else -> null
    }

    fun <T> withCodecMode(mode: AndroidCodecMode, action: () -> T): T {
        val previous = requestMode.get()
        requestMode.set(mode)
        try { return action() } finally {
            if (previous == null) requestMode.remove() else requestMode.set(previous)
        }
    }

    fun isCodecAllowed(hardware: Boolean, software: Boolean): Boolean =
        when (requestMode.get() ?: AndroidCodecMode.AUTO) {
            AndroidCodecMode.AUTO -> hardware || software
            AndroidCodecMode.HARDWARE -> hardware
            AndroidCodecMode.CPU -> software
        }

    fun codecPriority(hardware: Boolean): Int = if (hardware) 0 else 1

    fun boundedNonNegativeInt(value: Any?): Int? {
        val number = value as? Number ?: return null
        val normalized = number.toDouble()
        if (!normalized.isFinite() || normalized < 0.0 ||
            normalized > Int.MAX_VALUE || normalized % 1.0 != 0.0) return null
        return normalized.toInt()
    }

    fun createEncoder(width: Int, height: Int): MediaCodec? {
        val format = MediaFormat.createVideoFormat(MIME_AVC, width, height)
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, initialBitrateKbps(width, height) * 1_000)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
        return acquireConfiguredCodec(
            candidates = codecCandidates(isEncoder = true),
            create = { MediaCodec.createByCodecName(it.name) },
            configure = { it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) },
            release = { it.release() },
        )
    }

    fun createDecoder(width: Int, height: Int, outputSurface: android.view.Surface): MediaCodec? {
        val format = MediaFormat.createVideoFormat(MIME_AVC, width, height)
        return acquireConfiguredCodec(
            candidates = codecCandidates(isEncoder = false),
            create = { MediaCodec.createByCodecName(it.name) },
            configure = { it.configure(format, outputSurface, null, 0) },
            release = { it.release() },
        )
    }

    private fun codecCandidates(isEncoder: Boolean): List<MediaCodecInfo> {
        val infos = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        return infos.filter { info ->
            if (info.isEncoder != isEncoder) return@filter false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isAlias) {
                return@filter false
            }
            if (!info.supportedTypes.any { it.equals(MIME_AVC, ignoreCase = true) }) {
                return@filter false
            }
            val hardware = isHardware(info)
            val software = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                info.isSoftwareOnly
            } else { !hardware }
            isCodecAllowed(hardware, software)
        }.sortedBy { codecPriority(isHardware(it)) }
    }

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
        val name = info.name.lowercase()
        return !name.startsWith("omx.google.") &&
            !name.startsWith("c2.android.") &&
            !name.startsWith("omx.ffmpeg.")
    }

    fun initialBitrateKbps(width: Int, height: Int): Int {
        val raw = width.toLong() * height.toLong() * 4L
        return (raw / 1_000L).coerceIn(1_500L, 3 * 1024L).toInt()
    }
}
