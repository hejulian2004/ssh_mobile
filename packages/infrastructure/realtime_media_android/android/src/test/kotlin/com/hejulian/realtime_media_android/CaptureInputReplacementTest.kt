package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureInputReplacementTest {
    @Test
    fun replacesInputWithoutRecreatingProjectionOrDisplay() {
        val calls = mutableListOf<String>()
        assertTrue(replaceCaptureInput({ true },
            { calls.add("detach") }, { calls.add("release") },
            { calls.add("create") }, { calls.add("resize") }, { calls.add("attach") }))
        assertEquals(listOf("detach", "release", "create", "resize", "attach"), calls)
    }

    @Test
    fun stopAtAnySafePointPreventsTheNextPlatformOperation() {
        for (stopAfter in 0..4) {
            val calls = mutableListOf<String>()
            assertFalse(replaceCaptureInput({ calls.size < stopAfter },
                { calls.add("detach") }, { calls.add("release") },
                { calls.add("create") }, { calls.add("resize") }, { calls.add("attach") }))
            assertEquals(listOf("detach", "release", "create", "resize").take(stopAfter), calls)
        }
    }

    @Test
    fun failedCleanupCannotAcquireOrAttachAReplacement() {
        val calls = mutableListOf<String>()
        try {
            replaceCaptureInput({ true }, { calls.add("detach") },
                { calls.add("release"); throw IllegalStateException("release failed") },
                { calls.add("create") }, { calls.add("resize") }, { calls.add("attach") })
            throw AssertionError("cleanup failure was ignored")
        } catch (_: IllegalStateException) { }
        assertEquals(listOf("detach", "release"), calls)
    }
}
