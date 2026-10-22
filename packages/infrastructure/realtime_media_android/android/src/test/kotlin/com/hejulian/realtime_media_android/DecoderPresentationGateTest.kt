package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Test

class DecoderPresentationGateTest {
    @Test
    fun slowOrPausedTextureConsumerCannotFillTheSurfaceQueue() {
        var available = true
        val released = mutableListOf<Pair<Int, Boolean>>()
        val gate = DecoderPresentationGate(canRender = {
            available.also { available = false }
        }) { index, render -> released.add(index to render) }
        gate.offer(1, visible = true)
        gate.offer(2, visible = true)
        gate.offer(3, visible = true)
        gate.resume(visible = true)
        assertEquals(listOf(1 to true, 2 to false), released)
        available = true // Flutter reports the previous texture consumed.
        gate.resume(visible = false)
        gate.resume(visible = true)
        gate.resume(visible = true)
        assertEquals(listOf(1 to true, 2 to false, 3 to true), released)
    }

    @Test
    fun visibleOutputRendersImmediatelyWithoutRetainingBuffers() {
        val released = mutableListOf<Pair<Int, Boolean>>()
        val gate = DecoderPresentationGate { index, render -> released.add(index to render) }
        gate.offer(1, visible = true)
        gate.offer(2, visible = true)
        gate.resume(visible = true)
        gate.clear()
        assertEquals(listOf(1 to true, 2 to true), released)
    }

    @Test
    fun backgroundKeepsOnlyLatestOutputAndResumesWithoutNewInput() {
        val released = mutableListOf<Pair<Int, Boolean>>()
        val gate = DecoderPresentationGate { index, render -> released.add(index to render) }
        gate.offer(1, visible = false)
        gate.offer(2, visible = false)
        gate.offer(3, visible = false)
        gate.resume(visible = false)
        assertEquals(listOf(1 to false, 2 to false), released)
        gate.resume(visible = true)
        gate.resume(visible = true)
        assertEquals(listOf(1 to false, 2 to false, 3 to true), released)
    }

    @Test
    fun newVisibleOutputReleasesPendingBeforeRendering() {
        val released = mutableListOf<Pair<Int, Boolean>>()
        val gate = DecoderPresentationGate { index, render -> released.add(index to render) }
        gate.offer(4, visible = false)
        gate.offer(5, visible = true)
        gate.clear()
        assertEquals(listOf(4 to false, 5 to true), released)
    }

    @Test
    fun resetOrStopDiscardsPendingExactlyOnce() {
        val released = mutableListOf<Pair<Int, Boolean>>()
        val gate = DecoderPresentationGate { index, render -> released.add(index to render) }
        gate.offer(0, visible = false)
        gate.clear()
        gate.clear()
        gate.resume(visible = true)
        gate.offer(7, visible = false)
        gate.clear()
        assertEquals(listOf(0 to false, 7 to false), released)
    }

    @Test
    fun failedReleaseCannotBeReplayedAfterCodecFlush() {
        val released = mutableListOf<Int>()
        val gate = DecoderPresentationGate { index, _ ->
            released.add(index)
            throw IllegalStateException("codec ended")
        }
        gate.offer(8, visible = false)
        try { gate.clear() } catch (_: IllegalStateException) { }
        gate.clear()
        assertEquals(listOf(8), released)
    }
}
