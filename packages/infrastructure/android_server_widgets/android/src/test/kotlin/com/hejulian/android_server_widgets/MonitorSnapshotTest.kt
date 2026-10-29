package com.hejulian.android_server_widgets

import org.junit.Assert.*
import org.junit.Test

class MonitorSnapshotTest {
    private val now = 1793275200000L
    private fun payload() = mutableMapOf<String, Any?>(
        "schemaVersion" to 1, "connectionId" to "server-a", "displayName" to "Compute A",
        "sampledAt" to now, "cpuPercent" to 42.0, "memoryPercent" to 63.0,
        "networkBytesPerSecond" to 1024.0, "diskBytesPerSecond" to 2048.0,
        "effectiveIntervalMs" to 10000L, "status" to "active",
    )

    @Test fun normalizesUntrustedChannelDataAndVersion() {
        val input = payload()
        val snapshot = MonitorSnapshot.fromMap(input, now)!!
        assertEquals(input, snapshot.toMap())
        input["cpuPercent"] = Double.NaN
        input["memoryPercent"] = 101.0
        input["networkBytesPerSecond"] = -1.0
        input["diskBytesPerSecond"] = Double.POSITIVE_INFINITY
        val unknown = MonitorSnapshot.fromMap(input, now)!!
        assertNull(unknown.cpuPercent)
        assertNull(unknown.memoryPercent)
        assertNull(unknown.networkBytesPerSecond)
        assertNull(unknown.diskBytesPerSecond)
        input["schemaVersion"] = 2
        assertNull(MonitorSnapshot.fromMap(input, now))
    }

    @Test fun invalidTimeCannotClaimAnActiveSample() {
        for (time in listOf(0L, now + 60000)) {
            val snapshot = MonitorSnapshot.fromMap(payload().apply { put("sampledAt", time) }, now)!!
            assertNull(snapshot.sampledAt)
            assertNull(snapshot.cpuPercent)
            assertEquals(MonitorStatus.waiting, snapshot.status)
        }
        assertNull(MonitorSnapshot.fromMap(payload().apply { put("connectionId", "bad@id") }, now))
        val unknown = MonitorSnapshot.fromMap(payload().apply { put("status", "future") }, now)!!
        assertEquals(MonitorStatus.notConfigured, unknown.status)
    }

    @Test fun absoluteExpiryHonorsFiveMinuteSamplesAndStoppedState() {
        val slow = MonitorSnapshot.fromMap(payload().apply { put("effectiveIntervalMs", 300000) }, now)!!
        assertEquals(MonitorStatus.active, slow.statusAt(now + 899999))
        assertEquals(MonitorStatus.stale, slow.statusAt(now + 900000))
        val fast = MonitorSnapshot.fromMap(payload(), now)!!
        assertEquals(MonitorStatus.stale, fast.statusAt(now + 60000))
        assertEquals(MonitorStatus.stopped, fast.copy(status = MonitorStatus.stopped).statusAt(now + 900000))
        // The public model may be constructed directly; expiry itself must stay bounded.
        assertEquals(MonitorStatus.active, fast.copy(effectiveIntervalMs = Long.MAX_VALUE).statusAt(now + 899999))
        assertEquals(MonitorStatus.stale, fast.copy(effectiveIntervalMs = Long.MAX_VALUE).statusAt(now + 900000))
    }

    @Test fun labelsAndIdentifiersAreBoundedAndRedacted() {
        for (name in listOf("ssh://operator@192.0.2.1:22", "password=fixture", "2001:db8::1", "example.invalid:22", "token:fixture", "")) {
            assertEquals("Server", safeDisplayName(name))
        }
        assertEquals("A B", safeDisplayName("\u202eA\n B"))
        assertEquals(48, safeDisplayName("计算节点".repeat(100)).codePointCount(0, 48))
        assertFalse(validConnectionId("x".repeat(129)))
        assertFalse(validConnectionId(" bad "))
        assertTrue(validConnectionId("server-a"))
    }

    @Test fun missingFractionalAndInvalidFieldsCannotBecomeReadings() {
        assertNull(MonitorSnapshot.fromMap(emptyMap<Any, Any>(), now))
        assertNull(MonitorSnapshot.fromMap(payload().apply { put("schemaVersion", 1.5) }, now))
        assertNull(MonitorSnapshot.fromMap(payload().apply { remove("connectionId") }, now))
        val sample = MonitorSnapshot.fromMap(payload().apply {
            put("sampledAt", null); put("effectiveIntervalMs", -1); remove("displayName")
        }, now)!!
        assertEquals(10000L, sample.effectiveIntervalMs)
        assertEquals("Server", sample.displayName)
        assertNull(sample.cpuPercent)
        assertEquals(MonitorStatus.waiting, sample.statusAt(now))
        assertEquals(300000L, MonitorSnapshot.fromMap(payload().apply { put("effectiveIntervalMs", Long.MAX_VALUE) }, now)!!.effectiveIntervalMs)
        assertEquals(10000L, MonitorSnapshot.fromMap(payload().apply { remove("effectiveIntervalMs") }, now)!!.effectiveIntervalMs)
        assertEquals(1000L, MonitorSnapshot.fromMap(payload().apply { put("effectiveIntervalMs", 1) }, now)!!.effectiveIntervalMs)
        val bounds = MonitorSnapshot.fromMap(payload().apply {
            put("cpuPercent", 0); put("memoryPercent", 100); put("networkBytesPerSecond", 0); put("diskBytesPerSecond", null)
        }, now)!!
        assertEquals(0.0, bounds.cpuPercent!!, 0.0)
        assertEquals(100.0, bounds.memoryPercent!!, 0.0)
        assertEquals(0.0, bounds.networkBytesPerSecond!!, 0.0)
        assertNull(bounds.diskBytesPerSecond)
        assertEquals(48, safeDisplayName("\uD83D\uDE00".repeat(70)).codePointCount(0, 96))
        assertEquals("Server", safeDisplayName(" "))
    }
}
