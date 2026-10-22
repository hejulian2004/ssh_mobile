package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Test

class EncoderTimestampTimelineTest {
    @Test
    fun codecRestartKeepsPresentationTimestampsMovingForward() {
        val timeline = EncoderTimestampTimeline()
        assertEquals(90_000L, timeline.map(90_000))
        assertEquals(93_000L, timeline.map(93_000))
        assertEquals(93_001L, timeline.map(0))
        assertEquals(96_001L, timeline.map(3_000))
        assertEquals(96_002L, timeline.map(0))
        assertEquals(99_002L, timeline.map(3_000))
    }

    @Test
    fun repeatedTimestampDoesNotGoBackAndOffsetCannotOverflow() {
        val timeline = EncoderTimestampTimeline()
        assertEquals(0L, timeline.map(0))
        assertEquals(1L, timeline.map(0))
        assertEquals(Long.MAX_VALUE, timeline.map(Long.MAX_VALUE))
        assertEquals(Long.MAX_VALUE, timeline.map(0))
        assertEquals(Long.MAX_VALUE, timeline.map(1))
    }

    @Test(expected = IllegalArgumentException::class)
    fun negativeCodecTimeFailsClosed() {
        EncoderTimestampTimeline().map(-1)
    }
}
