package com.hejulian.realtime_media_android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidCodecFactoryTest {
    @Test
    fun cpuSelectionIsExplicitAndRestoresTheHardwareDefault() {
        assertFalse(AndroidCodecFactory.isCodecAllowed(false, true))
        assertTrue(AndroidCodecFactory.isCodecAllowed(true, false))
        AndroidCodecFactory.withCodecMode(AndroidCodecMode.CPU) {
            assertTrue(AndroidCodecFactory.isCodecAllowed(false, true))
            assertFalse(AndroidCodecFactory.isCodecAllowed(true, false))
            AndroidCodecFactory.withCodecMode(AndroidCodecMode.HARDWARE) {
                assertFalse(AndroidCodecFactory.isCodecAllowed(false, true))
            }
            assertTrue(AndroidCodecFactory.isCodecAllowed(false, true))
        }
        assertFalse(AndroidCodecFactory.isCodecAllowed(false, true))
    }

    @Test
    fun failureCannotLeakCpuSelectionToTheNextRequest() {
        try {
            AndroidCodecFactory.withCodecMode(AndroidCodecMode.CPU) {
                throw IllegalStateException("fixture-failure")
            }
        } catch (_: IllegalStateException) {}
        assertFalse(AndroidCodecFactory.isCodecAllowed(false, true))
        assertNull(AndroidCodecFactory.parseCodecMode("unknown"))
    }
}
