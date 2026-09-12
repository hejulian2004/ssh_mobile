package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

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
    fun releaseIfGrantedClaimsOnlyAnUnconsumedGrant() {
        val lease = ProjectionLeaseStateMachine()

        assertTrue(lease.releaseIfGranted())
        assertFalse(lease.releaseIfGranted())
        assertFalse(lease.consume(7))
        assertEquals(ProjectionLeaseState.RELEASED, lease.state)
    }

    @Test
    fun capturedGrantCompensationRunsTheBoundActionOnlyForCurrentGrantedLease() {
        val captured = Any()
        val other = Any()
        var releaseCalls = 0

        assertTrue(
            compensateCapturedProjectionGrant(
                capturedLease = captured,
                currentLease = captured,
                capturedState = ProjectionLeaseState.GRANTED,
                releaseIfGranted = {
                    releaseCalls++
                    true
                },
            ),
        )
        assertEquals(1, releaseCalls)

        assertFalse(
            compensateCapturedProjectionGrant(
                capturedLease = captured,
                currentLease = captured,
                capturedState = ProjectionLeaseState.GRANTED,
                releaseIfGranted = {
                    releaseCalls++
                    false
                },
            ),
        )
        assertEquals(2, releaseCalls)

        listOf(
            other to ProjectionLeaseState.GRANTED,
            captured to ProjectionLeaseState.CONSUMED,
            captured to ProjectionLeaseState.REVOKED,
            captured to ProjectionLeaseState.RELEASED,
        ).forEach { (current, state) ->
            assertFalse(
                compensateCapturedProjectionGrant(
                    capturedLease = captured,
                    currentLease = current,
                    capturedState = state,
                    releaseIfGranted = {
                        releaseCalls++
                        true
                    },
                ),
            )
        }
        assertEquals(2, releaseCalls)
    }

    @Test
    fun releaseIfGrantedCompetesWithConsumeAndRevokeAtOneTransitionBoundary() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            repeat(64) {
                val lease = ProjectionLeaseStateMachine()
                val ready = CountDownLatch(1)
                val consume = executor.submit<Boolean> {
                    ready.await()
                    lease.consume(7)
                }
                val release = executor.submit<Boolean> {
                    ready.await()
                    lease.releaseIfGranted()
                }
                ready.countDown()

                val consumed = consume.get(2, TimeUnit.SECONDS)
                val released = release.get(2, TimeUnit.SECONDS)
                assertEquals(1, listOf(consumed, released).count { it })
                assertTrue(
                    lease.state == ProjectionLeaseState.CONSUMED ||
                        lease.state == ProjectionLeaseState.RELEASED,
                )
                if (consumed) {
                    assertEquals(ProjectionLeaseState.CONSUMED, lease.state)
                    assertEquals(7L, lease.ownerToken)
                    assertFalse(lease.releaseIfGranted())
                } else {
                    assertEquals(ProjectionLeaseState.RELEASED, lease.state)
                    assertNull(lease.ownerToken)
                    assertFalse(lease.consume(8))
                }
            }

            repeat(64) {
                val lease = ProjectionLeaseStateMachine()
                val ready = CountDownLatch(1)
                val revoke = executor.submit<ProjectionLeaseRevocation> {
                    ready.await()
                    lease.revoke()
                }
                val release = executor.submit<Boolean> {
                    ready.await()
                    lease.releaseIfGranted()
                }
                ready.countDown()

                val revoked = revoke.get(2, TimeUnit.SECONDS)
                val released = release.get(2, TimeUnit.SECONDS)
                assertEquals(1, listOf(revoked.changed, released).count { it })
                if (released) {
                    assertEquals(ProjectionLeaseState.RELEASED, lease.state)
                    assertFalse(revoked.changed)
                } else {
                    assertEquals(ProjectionLeaseState.REVOKED, lease.state)
                    assertTrue(revoked.changed)
                    assertFalse(lease.releaseIfGranted())
                }
            }
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun revokeRetainsConsumedOwnerForDeferredCleanup() {
        val lease = ProjectionLeaseStateMachine()
        lease.consume(7)

        assertEquals(7L, lease.revoke().ownerToken)
        assertEquals(ProjectionLeaseState.REVOKED, lease.state)
        assertEquals(7L, lease.ownerToken)
        assertTrue(lease.release())
        assertEquals(ProjectionLeaseState.RELEASED, lease.state)
    }
}
