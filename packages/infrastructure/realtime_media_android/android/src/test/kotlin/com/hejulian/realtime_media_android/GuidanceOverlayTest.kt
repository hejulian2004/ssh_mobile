package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GuidanceOverlayTest {
    @Test
    fun overlayWindowDoesNotTakeFocusOrTouches() {
        assertEquals(2038, GuidanceOverlaySpec.windowType(26))
        assertEquals(2038, GuidanceOverlaySpec.windowType(34))
        assertEquals(2002, GuidanceOverlaySpec.windowType(23))
        assertEquals(8 or 16 or 32 or 256, GuidanceOverlaySpec.layoutFlags)
        assertTrue(GuidanceOverlaySpec.layoutFlags and GuidanceOverlaySpec.flagNotFocusable != 0)
        assertTrue(GuidanceOverlaySpec.layoutFlags and GuidanceOverlaySpec.flagNotTouchable != 0)
        assertTrue(GuidanceOverlaySpec.layoutFlags and GuidanceOverlaySpec.flagNotTouchModal != 0)
        assertTrue(GuidanceOverlaySpec.layoutFlags and GuidanceOverlaySpec.flagLayoutInScreen != 0)
    }

    @Test
    fun deniedPermissionDoesNotAttachAndStopReleasesOnce() {
        val host = FakeGuidanceHost()
        val controller = GuidanceOverlayController(host)
        val snapshot = GuidanceOverlaySnapshot(1080, 2400, emptyList(), null)
        assertFalse(controller.present(snapshot))
        assertEquals(1, host.permissionRequests)
        assertFalse(controller.present(snapshot))
        assertEquals(1, host.permissionRequests)
        assertEquals(0, host.attachCount)
        host.allowed = true
        assertTrue(controller.present(snapshot))
        assertEquals(1, host.attachCount)
        assertEquals(1, host.renderCount)
        controller.hide()
        controller.hide()
        assertEquals(1, host.detachCount)
        assertFalse(controller.visible)
    }

    @Test
    fun contentRectLetterboxesANarrowerCaptureFrame() {
        val rect = guidanceContentRect(1000, 2000, 1000, 1000)
        assertEquals(0f, rect.left)
        assertEquals(500f, rect.top)
        assertEquals(1000f, rect.width)
        assertEquals(1000f, rect.height)
    }

    @Test
    fun malformedSnapshotIsIgnored() {
        assertNull(guidanceSnapshot(mapOf("width" to 0, "height" to 10)))
        assertNull(guidanceSnapshot(mapOf("width" to 10, "height" to 10, "strokes" to listOf("x"))))
        val snapshot = guidanceSnapshot(
            mapOf(
                "width" to 1080,
                "height" to 2400,
                "strokes" to listOf(
                    mapOf("color" to 1, "width" to 24, "points" to listOf(0, 65535)),
                ),
            ),
        )
        val parsed = checkNotNull(snapshot)
        assertEquals(65535, parsed.strokes.single().points.single().y)
    }
}

private class FakeGuidanceHost : GuidanceOverlayHost {
    var allowed = false
    var permissionRequests = 0
    var attachCount = 0
    var detachCount = 0
    var renderCount = 0

    override fun canDrawOverlays(): Boolean = allowed

    override fun requestPermission() {
        permissionRequests += 1
    }

    override fun attach(width: Int, height: Int) {
        attachCount += 1
    }

    override fun detach() {
        detachCount += 1
    }

    override fun render(snapshot: GuidanceOverlaySnapshot) {
        renderCount += 1
    }
}
