package com.hejulian.realtime_media_android

/** Preserves one owner's 90 kHz timeline when a replacement codec resets PTS. */
internal class EncoderTimestampTimeline {
    private var offset = 0L
    private var last = -1L

    fun map(source: Long): Long {
        require(source >= 0)
        var mapped = if (source > Long.MAX_VALUE - offset) Long.MAX_VALUE else source + offset
        if (mapped <= last) {
            mapped = if (last == Long.MAX_VALUE) last else last + 1
            offset = mapped - source
        }
        last = mapped
        return mapped
    }
}
