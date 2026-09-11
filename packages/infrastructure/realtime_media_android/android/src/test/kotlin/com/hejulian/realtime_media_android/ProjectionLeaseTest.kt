package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectionLeaseTest {
    @Test
    fun leaseCanBeConsumedOnlyOnceAndReleasedIdempotently() {
        val lease = ProjectionLeaseStateMachine()

        assertTrue(lease.consume(7))
        assertFalse(lease.consume(8))
        assertEquals(ProjectionLeaseState.CONSUMED, lease.state)
        assertEquals(7L, lease.ownerToken)

        assertTrue(lease.release())
        assertFalse(lease.release())
        assertEquals(ProjectionLeaseState.RELEASED, lease.state)
        assertNull(lease.ownerToken)
    }

    @Test
    fun revokeRetainsConsumedOwnerForDeferredCleanup() {
        val lease = ProjectionLeaseStateMachine()
        lease.consume(7)

        assertEquals(7L, lease.revoke())
        assertEquals(ProjectionLeaseState.REVOKED, lease.state)
        assertEquals(7L, lease.ownerToken)
        assertTrue(lease.release())
        assertEquals(ProjectionLeaseState.RELEASED, lease.state)
    }
}
