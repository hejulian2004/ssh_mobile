package com.example.ssh_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WindowSnapshotLeaseTest {
    @Test
    fun restoresOriginalWindowStateAndIgnoresStaleDisposal() {
        var flags = 17
        val owner = WindowSnapshotLease(read = { flags }, enter = { flags = 99 },
            restore = { flags = it })
        assertFalse(owner.setFullscreen(0, true))
        assertTrue(owner.setFullscreen(1, true))
        assertTrue(owner.setFullscreen(1, true))
        assertFalse(owner.setFullscreen(2, true))
        assertTrue(owner.setFullscreen(2, false))
        assertEquals(99, flags)
        owner.refresh()
        assertTrue(owner.setFullscreen(1, false))
        assertEquals(17, flags)
        assertTrue(owner.setFullscreen(1, false))
        flags = 42
        assertTrue(owner.setFullscreen(3, true))
        assertTrue(owner.setFullscreen(1, false))
        assertEquals(99, flags)
        owner.close()
        assertEquals(42, flags)
        owner.refresh()
    }

    @Test
    fun failedRestoreKeepsOriginalSnapshotForRetry() {
        var flags = 17
        var failRestore = true
        val owner = WindowSnapshotLease(read = { flags }, enter = { flags = 99 },
            restore = { if (failRestore) throw IllegalStateException(); flags = it })
        assertTrue(owner.setFullscreen(1, true))
        assertFalse(owner.setFullscreen(1, false))
        assertFalse(owner.setFullscreen(2, true))
        failRestore = false
        assertTrue(owner.setFullscreen(1, false))
        assertEquals(17, flags)
    }

    @Test
    fun partialEntryIsCompensatedAndSnapshotFailureChangesNothing() {
        var flags = 17
        val partial = WindowSnapshotLease(read = { flags },
            enter = { flags = 99; throw IllegalStateException() }, restore = { flags = it })
        assertFalse(partial.setFullscreen(1, true))
        assertEquals(17, flags)
        val unavailable = WindowSnapshotLease<Int>(read = { throw IllegalStateException() },
            enter = { flags = 99 }, restore = { flags = it })
        assertFalse(unavailable.setFullscreen(2, true))
        assertEquals(17, flags)
        unavailable.close()
    }
}
