package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidMediaOwnerReleaseTest {
    @Test
    fun stopFailureDoesNotCloseAndASecondReleaseCanRetry() {
        val calls = mutableListOf<String>()
        var stopStatus = -9

        val firstStatus = releaseNativeOwner(
            stopOwner = {
                calls += "stop"
                stopStatus
            },
            closeOwner = {
                calls += "close"
                0
            },
        )

        assertEquals(-9, firstStatus)
        assertEquals(listOf("stop"), calls)

        stopStatus = 0
        val retryStatus = releaseNativeOwner(
            stopOwner = {
                calls += "stop"
                stopStatus
            },
            closeOwner = {
                calls += "close"
                0
            },
        )

        assertEquals(0, retryStatus)
        assertEquals(listOf("stop", "stop", "close"), calls)
    }

    @Test
    fun successfulStopAllowsCloseAndPropagatesCloseFailure() {
        val calls = mutableListOf<String>()

        val status = releaseNativeOwner(
            stopOwner = {
                calls += "stop"
                0
            },
            closeOwner = {
                calls += "close"
                -3
            },
        )

        assertEquals(-3, status)
        assertEquals(listOf("stop", "close"), calls)
    }
}
