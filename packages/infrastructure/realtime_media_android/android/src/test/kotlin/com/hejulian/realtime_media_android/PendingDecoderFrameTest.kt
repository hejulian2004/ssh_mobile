package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingDecoderFrameTest {
    @Test
    fun inputBackpressureRetainsOneFrameWithoutPullingAgain() {
        val pending = PendingDecoderFrame<String>()
        var pulls = 0
        val first = pending.acquire {
            pulls++
            "keyframe"
        }
        assertEquals("keyframe", first)
        assertTrue(pending.hasPending)

        val retry = pending.acquire {
            pulls++
            "replacement"
        }
        assertSame(first, retry)
        assertEquals(1, pulls)

        pending.markQueued()
        assertFalse(pending.hasPending)
    }

    @Test
    fun resetDropsPendingDeltaBeforeTheNextRecoveryFrame() {
        val pending = PendingDecoderFrame<String>()
        pending.acquire { "delta" }
        pending.clear()

        assertFalse(pending.hasPending)
        assertEquals("fresh-idr", pending.acquire { "fresh-idr" })
    }
}
