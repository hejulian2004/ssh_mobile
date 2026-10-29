package com.hejulian.android_server_widgets

import org.junit.Assert.*
import org.junit.Test

class WidgetWriteTest {
    private fun payload() = mutableMapOf<String, Any?>(
        "session" to "writer-a", "sequence" to 1L,
        "servers" to listOf(mapOf("connectionId" to "a", "displayName" to "Compute A")),
        "snapshots" to emptyList<Any>(), "invalidatedBefore" to mapOf("a" to 1L), "reset" to true,
    )

    @Test fun decodesOnlySafeFieldsAndBoundsEveryCollection() {
        val write = WidgetWrite.fromMap(payload())
        assertEquals("writer-a", write.session)
        assertEquals(1L, write.sequence)
        assertEquals(listOf(WidgetServer("a", "Compute A")), write.servers)
        assertEquals(mapOf("a" to 1L), write.invalidatedBefore)
        assertTrue(write.reset)
        for ((key, value) in listOf(
            "session" to "", "sequence" to -1L, "servers" to List(101) { emptyMap<String, Any>() },
            "snapshots" to List(101) { emptyMap<String, Any>() },
            "invalidatedBefore" to (0..100).associate { "a-$it" to 1L },
            "servers" to listOf(mapOf("connectionId" to "bad@id")),
        )) {
            try { WidgetWrite.fromMap(payload().apply { put(key, value) }); fail("must reject $key") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun malformedPayloadsAreRejectedAndSnapshotFieldsAreWhitelisted() {
        val now = 1793275200000L
        val snapshot = mapOf(
            "schemaVersion" to 1, "connectionId" to "a", "displayName" to "Compute A", "sampledAt" to now,
            "cpuPercent" to 10.0, "memoryPercent" to 20.0, "networkBytesPerSecond" to 30.0,
            "diskBytesPerSecond" to 40.0, "effectiveIntervalMs" to 10000L, "status" to "active",
            "ignoredConfig" to "fixture-never-persisted",
        )
        val write = WidgetWrite.fromMap(payload().apply { put("snapshots", listOf(snapshot)); remove("reset") }, now)
        assertEquals(10.0, write.snapshots.single().cpuPercent!!, 0.0)
        assertFalse(write.snapshots.single().toMap().containsKey("ignoredConfig"))
        assertFalse(write.reset)
        for ((key, value) in listOf(
            "session" to null, "sequence" to null, "servers" to null, "snapshots" to null,
            "invalidatedBefore" to null, "servers" to listOf("wrong type"),
            "servers" to listOf(emptyMap<String, Any>()),
            "snapshots" to listOf("wrong type"), "snapshots" to listOf(snapshot, snapshot),
            "servers" to (payload()["servers"] as List<*>) + (payload()["servers"] as List<*>),
            "invalidatedBefore" to mapOf("bad@id" to 1L),
            "invalidatedBefore" to mapOf("a" to null), "invalidatedBefore" to mapOf("a" to -1L),
        )) {
            try { WidgetWrite.fromMap(payload().apply { put(key, value) }, now); fail("must reject $key") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
