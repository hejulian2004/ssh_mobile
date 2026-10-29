package com.example.ssh_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PictureInPictureCoordinatorTest {
    @Test
    fun aspectStaysInsideThePlatformRange() {
        val wide = PictureInPictureAspect.of(1920.0, 1080.0)
        assertEquals(17778 to 10000, wide)
        val tall = PictureInPictureAspect.of(1.0, 100000.0)!!
        val cinema = PictureInPictureAspect.of(100000.0, 1.0)!!
        assertTrue(tall.first.toDouble() / tall.second >= 1.0 / 2.39)
        assertTrue(cinema.first.toDouble() / cinema.second <= 2.39)
        assertNull(PictureInPictureAspect.of(0.0, 10.0))
        assertNull(PictureInPictureAspect.of(Double.NaN, 10.0))
        assertNull(PictureInPictureAspect.of(-1.0, 10.0))
    }

    @Test
    fun publishesAutoEnterOnlyWhileAReceiverFrameIsEligible() {
        val host = Host(sdk31 = true)
        val coordinator = PictureInPictureCoordinator(host)
        coordinator.setVideoAspect(1920.0, 1080.0)
        coordinator.setVideoAspect(1920.0, 1080.0)
        assertEquals(listOf("apply:17778x10000:true"), host.events)
        coordinator.setVideoAspect(null, null)
        assertEquals(
            listOf("apply:17778x10000:true", "apply:null:false"),
            host.events,
        )
        assertFalse(host.events.contains("expand"))
    }

    @Test
    fun releaseWhileActiveClearsEligibilityWithoutStartingTheActivity() {
        val host = Host(sdk31 = true, active = true)
        val coordinator = PictureInPictureCoordinator(host)
        coordinator.setVideoAspect(16.0, 9.0)
        coordinator.release()
        assertTrue(host.events.contains("apply:null:false"))
        assertFalse(host.events.contains("expand"))
        assertFalse(host.events.any { it.startsWith("start") })
    }

    @Test
    fun stoppingAnActiveWindowExpandsBackToTheSameActivity() {
        val host = Host(sdk31 = true, active = true)
        val coordinator = PictureInPictureCoordinator(host)
        coordinator.setVideoAspect(16.0, 9.0)
        coordinator.setVideoAspect(0.0, 1.0)
        assertTrue(host.events.contains("expand"))
        assertTrue(coordinator.shouldAvoidFinish())
    }

    @Test
    fun homeSuspendsImmersiveAndEntersOnlyBeforeAutoEnter() {
        val modern = Host(sdk31 = true)
        PictureInPictureCoordinator(modern).apply {
            setVideoAspect(16.0, 9.0)
            onUserLeaveHint()
        }
        assertTrue(modern.events.contains("suspend"))
        assertFalse(modern.events.any { it.startsWith("enter") })

        val legacy = Host(sdk31 = false)
        PictureInPictureCoordinator(legacy).apply {
            setVideoAspect(16.0, 9.0)
            onUserLeaveHint()
        }
        assertTrue(legacy.events.contains("suspend"))
        assertTrue(legacy.events.any { it.startsWith("enter") })

        val rejected = Host(sdk31 = false, enterResult = false)
        PictureInPictureCoordinator(rejected).apply {
            setVideoAspect(16.0, 9.0)
            onUserLeaveHint()
        }
        assertEquals("resume", rejected.events.last())
    }

    @Test
    fun inactiveShareDoesNotEnterAndOldPlatformIgnoresTheSession() {
        val idle = Host(sdk31 = false)
        PictureInPictureCoordinator(idle).onUserLeaveHint()
        assertTrue(idle.events.isEmpty())

        val old = Host(sdk26 = false, sdk31 = false)
        PictureInPictureCoordinator(old).setVideoAspect(16.0, 9.0)
        assertTrue(old.events.isEmpty())
        assertFalse(PictureInPictureCoordinator(old).shouldAvoidFinish())
    }

    @Test
    fun modeChangesSuspendAndRestoreTheFullscreenLease() {
        val host = Host()
        val coordinator = PictureInPictureCoordinator(host)
        coordinator.onModeChanged(true)
        coordinator.onModeChanged(false)
        assertEquals(listOf("suspend", "flutter:true", "resume", "flutter:false"), host.events)
    }

    private class Host(
        private val sdk26: Boolean = true,
        private val sdk31: Boolean = true,
        var active: Boolean = false,
        private val enterResult: Boolean = true,
    ) : PictureInPictureHost {
        val events = mutableListOf<String>()

        override fun sdkAtLeast26(): Boolean = sdk26

        override fun sdkAtLeast31(): Boolean = sdk31

        override fun isActive(): Boolean = active

        override fun suspendImmersive() {
            events += "suspend"
        }

        override fun resumeImmersive() {
            events += "resume"
        }

        override fun apply(aspect: Pair<Int, Int>?, autoEnter: Boolean) {
            events += "apply:${aspect?.let { "${it.first}x${it.second}" } ?: "null"}:$autoEnter"
        }

        override fun enter(aspect: Pair<Int, Int>): Boolean {
            events += "enter:${aspect.first}x${aspect.second}"
            if (enterResult) active = true
            return enterResult
        }

        override fun expand() {
            events += "expand"
        }

        override fun notifyFlutter(active: Boolean) {
            events += "flutter:$active"
        }
    }
}
