package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Test

class ForegroundReadinessRequestTest {
    @Test
    fun serviceReadinessCompletesOnceAndCancelsItsDeadline() {
        val outcomes = mutableListOf<Int>()
        var cancelled = 0
        lateinit var ready: (Int) -> Unit
        lateinit var timeout: () -> Unit
        val request = ForegroundReadinessRequest(outcomes::add, { callback ->
            timeout = callback
            val cancel: () -> Unit = { cancelled++ }
            cancel
        })
        request.start { ready = it }
        ready(ForegroundReadinessRequest.READY)
        ready(ForegroundReadinessRequest.FAILED)
        timeout()
        request.cancel()
        assertEquals(listOf(ForegroundReadinessRequest.READY), outcomes)
        assertEquals(1, cancelled)
    }

    @Test
    fun cancellationAndTimeoutCannotAllowLateDecoderStart() {
        for (cancel in listOf(true, false)) {
            val outcomes = mutableListOf<Int>()
            lateinit var ready: (Int) -> Unit
            lateinit var timeout: () -> Unit
            val request = ForegroundReadinessRequest(outcomes::add, { callback ->
                timeout = callback
                val cancel: () -> Unit = {}
                cancel
            })
            request.start { ready = it }
            if (cancel) request.cancel() else timeout()
            ready(ForegroundReadinessRequest.READY)
            assertEquals(listOf(if (cancel) ForegroundReadinessRequest.CANCELLED
                else ForegroundReadinessRequest.TIMED_OUT), outcomes)
        }
    }

    @Test
    fun cancelledRequestDoesNotStartAnotherService() {
        val outcomes = mutableListOf<Int>()
        val request = ForegroundReadinessRequest(outcomes::add, { {} })
        request.cancel()
        request.start { throw AssertionError("cancelled start") }
        assertEquals(listOf(ForegroundReadinessRequest.CANCELLED), outcomes)
    }

    @Test
    fun synchronousTimeoutStillCancelsItsReturnedTimer() {
        val outcomes = mutableListOf<Int>()
        var cancelled = 0
        val request = ForegroundReadinessRequest(outcomes::add, { callback ->
            callback()
            val cancel: () -> Unit = { cancelled++ }
            cancel
        })
        request.start { throw AssertionError("expired start") }
        assertEquals(listOf(ForegroundReadinessRequest.TIMED_OUT), outcomes)
        assertEquals(1, cancelled)
    }

    @Test
    fun startFailuresAreTypedAndNeverCompleteAgain() {
        for (error in listOf(SecurityException(), IllegalStateException())) {
            val outcomes = mutableListOf<Int>()
            val request = ForegroundReadinessRequest(outcomes::add, { {} })
            request.start { throw error }
            request.cancel()
            assertEquals(listOf(if (error is SecurityException) ForegroundReadinessRequest.DENIED
                else ForegroundReadinessRequest.FAILED), outcomes)
        }
    }
}
