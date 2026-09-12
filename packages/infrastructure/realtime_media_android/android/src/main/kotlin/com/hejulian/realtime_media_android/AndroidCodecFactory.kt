package com.hejulian.realtime_media_android

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

/** Hardware-only MediaCodec selection. Software codec names are rejected. */
internal object AndroidCodecFactory {
    private const val MIME_AVC = "video/avc"

    fun createEncoder(width: Int, height: Int): MediaCodec? {
        val info = findCodec(isEncoder = true) ?: return null
        val format = MediaFormat.createVideoFormat(MIME_AVC, width, height)
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, initialBitrateKbps(width, height) * 1_000)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        return try {
            MediaCodec.createByCodecName(info.name).also {
                it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
        } catch (_: Exception) {
            null
        }
    }

    fun createDecoder(width: Int, height: Int, outputSurface: android.view.Surface): MediaCodec? {
        val info = findCodec(isEncoder = false) ?: return null
        val format = MediaFormat.createVideoFormat(MIME_AVC, width, height)
        return try {
            MediaCodec.createByCodecName(info.name).also { it.configure(format, outputSurface, null, 0) }
        } catch (_: Exception) {
            null
        }
    }

    private fun findCodec(isEncoder: Boolean): MediaCodecInfo? {
        val infos = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        return infos.firstOrNull { info ->
            if (info.isEncoder != isEncoder) return@firstOrNull false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isAlias) {
                return@firstOrNull false
            }
            if (!info.supportedTypes.any { it.equals(MIME_AVC, ignoreCase = true) }) {
                return@firstOrNull false
            }
            isHardware(info)
        }
    }

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isHardwareAccelerated) return true
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
