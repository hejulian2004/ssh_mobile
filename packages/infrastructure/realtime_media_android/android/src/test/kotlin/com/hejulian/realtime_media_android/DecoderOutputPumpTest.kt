package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderOutputPumpTest {
    @Test
    fun delayedSingleFrameRendersWithoutAnotherInput() {
        var hasInput = true
        var ready = false
        val rendered = mutableListOf<Int>()
        val pump = DecoderOutputPump(
            isActive = { true },
            submitInput = { hasInput.also { hasInput = false } },
            readOutput = { if (ready) { ready = false; 0 } else -1 },
            renderOutput = rendered::add,
        )
        assertTrue(pump.step())
        assertTrue(rendered.isEmpty())
        ready = true
        assertFalse(pump.step())
        assertEquals(listOf(0), rendered)
    }

    @Test
    fun formatNotificationsDoNotHideAnAvailableFrame() {
        val statuses = ArrayDeque(listOf(-2, -3, 4, -1))
        val rendered = mutableListOf<Int>()
        val pump = DecoderOutputPump({ true }, { true },
            { statuses.removeFirstOrNull() ?: -1 }, rendered::add)
        pump.step()
        assertEquals(listOf(4), rendered)
    }

    @Test
    fun stoppedOwnerDoesNotSubmitOrPublishCodecOutput() {
        var active = false
        var reads = 0
        val pump = DecoderOutputPump({ active }, { active = false; true },
            { reads++; -1 }, { throw AssertionError("stopped output") })
        assertFalse(pump.step())
        assertEquals(0, reads)
        active = true
        pump.step()
        assertEquals(1, reads)
    }

    @Test
    fun aBusyCodecCannotKeepOneDrainUnbounded() {
        var reads = 0
        val pump = DecoderOutputPump({ true }, { false }, { reads++; -2 }, {})
        pump.step()
        assertEquals(32, reads)
    }

    @Test(expected = IllegalStateException::class)
    fun unknownOutputStatusFailsClosed() {
        DecoderOutputPump({ true }, { true }, { -4 }, {}).step()
    }

    @Test
    fun outputReleaseCanStopTheOwnerBeforeAnotherInput() {
        var active = true
        var rendered = 0
        val pump = DecoderOutputPump({ active },
            { throw AssertionError("stopped input") }, { 0 },
            { rendered++; active = false })
        assertFalse(pump.step())
        assertEquals(1, rendered)
    }
}
