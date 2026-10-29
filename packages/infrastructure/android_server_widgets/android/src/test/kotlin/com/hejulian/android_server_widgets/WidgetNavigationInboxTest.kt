package com.hejulian.android_server_widgets

import org.junit.Assert.*
import org.junit.Test

class WidgetNavigationInboxTest {
    private fun request(index: Int) = "00000000-0000-4000-8000-${index.toString().padStart(12, '0')}"

    @Test fun validatesAndDeduplicatesColdAndWarmNavigationWithoutPerformingActions() {
        val inbox = WidgetNavigationInbox()
        assertNull(inbox.take())
        assertFalse(inbox.offer("other-action", "a", request(1)))
        assertFalse(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, "bad@id", request(1)))
        assertFalse(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, "a", "bad/request"))
        assertFalse(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, null, request(1)))
        assertTrue(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, "a", request(1)))
        assertFalse(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, "a", request(1)))
        assertEquals(mapOf("connectionId" to "a", "requestId" to request(1)), inbox.take())
        assertNull(inbox.take())
        for (id in 2..40) assertTrue(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, "a", request(id)))
        assertEquals(request(33), inbox.take()!!["requestId"])
        repeat(7) { assertNotNull(inbox.take()) }
        assertNull(inbox.take())
        assertTrue(inbox.offer(WidgetNavigationInbox.ACTION_OPEN_MONITOR, "a", request(1)))
    }
}
