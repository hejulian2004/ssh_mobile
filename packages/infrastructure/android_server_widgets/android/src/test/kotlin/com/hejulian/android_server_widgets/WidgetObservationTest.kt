package com.hejulian.android_server_widgets

import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.single
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WidgetObservationTest {
    @get:Rule val temp = TemporaryFolder()
    private val now = 1793275200000L

    @Test fun activeSubscriberReceivesAtomicFirstSampleChangedSampleAndRemoval() = runBlocking {
        withTimeout(10000) {
            val job = SupervisorJob()
            val repository = MonitorSnapshotRepository(DataStoreFactory.create(
                serializer = MonitorStoreSerializer,
                corruptionHandler = ReplaceFileCorruptionHandler { MonitorStore() },
                scope = CoroutineScope(Dispatchers.IO + job),
                produceFile = { File(temp.root, "observed-snapshots.bin") },
            ), clock = { now })
            val events = Channel<MonitorSnapshotState>(Channel.UNLIMITED)
            val collector = launch { repository.observeState().collect { events.send(it) } }
            try {
                assertEquals(MonitorSnapshotState(), events.receive())
                val session = repository.beginSession()
                val servers = listOf(WidgetServer("a", "Compute A"))
                val first = MonitorSnapshot("a", "Compute A", now - 1, 42.0, 63.0, 1024.0, 2048.0, 10000, MonitorStatus.active)
                repository.synchronize(session, 1, servers, listOf(first), emptyMap(), false)
                val observed = events.receive()
                assertEquals(servers, observed.servers)
                assertEquals(42.0, observed.snapshots.getValue("a").cpuPercent!!, 0.0)
                repository.synchronize(session, 2, servers, listOf(first.copy(cpuPercent = 44.0, sampledAt = now)), emptyMap(), false)
                val changed = events.receive()
                assertEquals(44.0, changed.snapshots.getValue("a").cpuPercent!!, 0.0)
                assertEquals(now, changed.snapshots.getValue("a").sampledAt)
                repository.synchronize(session, 3, emptyList(), emptyList(), emptyMap(), false)
                assertEquals(MonitorSnapshotState(), events.receive())
            } finally {
                collector.cancelAndJoin()
                job.cancelAndJoin()
            }
        }
    }

    @Test fun activeSubscriberReceivesConfigurationAndDeletionForOnlyTheirInstance() = runBlocking {
        withTimeout(10000) {
            val job = SupervisorJob()
            val repository = WidgetInstanceRepository(DataStoreFactory.create(
                serializer = WidgetInstancesSerializer,
                corruptionHandler = ReplaceFileCorruptionHandler { emptyMap() },
                scope = CoroutineScope(Dispatchers.IO + job),
                produceFile = { File(temp.root, "observed-instances.bin") },
            ))
            val events = Channel<Map<Int, String>>(Channel.UNLIMITED)
            val collector = launch { repository.observeMappings().collect { events.send(it) } }
            try {
                assertTrue(events.receive().isEmpty())
                repository.configure(11, "a")
                assertEquals(mapOf(11 to "a"), events.receive())
                repository.configure(12, "b")
                assertEquals(mapOf(11 to "a", 12 to "b"), events.receive())
                repository.removeWidgets(setOf(11))
                assertEquals(mapOf(12 to "b"), events.receive())
            } finally {
                collector.cancelAndJoin()
                job.cancelAndJoin()
            }
        }
    }

    @Test fun observationFailureEmitsSafeEmptyStateWithoutCreatingWritableFallback() = runBlocking {
        val snapshots = MonitorSnapshotRepository(failingStore<MonitorStore>(IOException("fixture read failure")), clock = { now })
        assertEquals(MonitorSnapshotState(), snapshots.observeState().single())
        val mappings = WidgetInstanceRepository(failingStore<Map<Int, String>>(IOException("fixture read failure")))
        assertTrue(mappings.observeMappings().single().isEmpty())
        try { mappings.configure(1, "a"); fail("write failure must propagate") } catch (_: IOException) { }
        try { snapshots.beginSession(); fail("write failure must propagate") } catch (_: IOException) { }
        val broken = MonitorSnapshotRepository(failingStore<MonitorStore>(IllegalStateException("fixture programming error")))
        try { broken.observeState().single(); fail("non-I/O failure must propagate") } catch (_: IllegalStateException) { }
        val brokenMappings = WidgetInstanceRepository(failingStore<Map<Int, String>>(IllegalStateException("fixture programming error")))
        try { brokenMappings.observeMappings().single(); fail("non-I/O failure must propagate") } catch (_: IllegalStateException) { }
    }

    @Test fun observedReadingsAreNormalizedAndExpireAgainstAbsoluteClock() = runBlocking {
        val sample = MonitorSnapshot("a", "Compute A", now - 60000, Double.NaN, 63.0, 1024.0, 2048.0, 10000, MonitorStatus.active)
        val store = object : DataStore<MonitorStore> {
            override val data: Flow<MonitorStore> = flowOf(MonitorStore(
                servers = listOf(WidgetServer("a", "Compute A")), snapshots = mapOf("a" to sample),
            ))
            override suspend fun updateData(transform: suspend (MonitorStore) -> MonitorStore): MonitorStore =
                throw UnsupportedOperationException("read-only fixture")
        }
        val observed = MonitorSnapshotRepository(store, clock = { now }).observeState().single()
        assertEquals(now - 60000, observed.snapshots.getValue("a").sampledAt)
        assertEquals(MonitorStatus.stale, observed.snapshots.getValue("a").status)
        assertNull(observed.snapshots.getValue("a").cpuPercent)
        assertEquals(63.0, observed.snapshots.getValue("a").memoryPercent!!, 0.0)
    }

    private fun <T> failingStore(error: Exception): DataStore<T> = object : DataStore<T> {
        override val data: Flow<T> = flow { throw error }
        override suspend fun updateData(transform: suspend (T) -> T): T = throw IOException("fixture write failure")
    }
}
