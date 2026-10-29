package com.hejulian.android_server_widgets

import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MonitorSnapshotRepositoryTest {
    @get:Rule val temporary = TemporaryFolder()
    private val now = 1793275200000L
    private val servers = listOf(WidgetServer("a", "Compute A"), WidgetServer("b", "Compute B"))
    private fun sample(id: String, status: MonitorStatus = MonitorStatus.active, time: Long? = now) =
        MonitorSnapshot(id, "Compute", time, 42.0, 63.0, 1024.0, 2048.0, 10000, status)
    private fun open(file: File, job: kotlinx.coroutines.Job): MonitorSnapshotRepository = MonitorSnapshotRepository(
        DataStoreFactory.create(
            serializer = MonitorStoreSerializer,
            corruptionHandler = ReplaceFileCorruptionHandler { MonitorStore() },
            scope = CoroutineScope(Dispatchers.IO + job),
            produceFile = { file },
        ),
        clock = { now },
    )

    @Test fun persistsFourMetricsAcrossProcessOwnerRecreationAndKeepsLastSuccess() = runBlocking {
        val file = File(temporary.root, "snapshots.bin")
        val job = SupervisorJob()
        val first = open(file, job)
        val session = first.beginSession()
        first.synchronize(session, 1, servers, listOf(sample("a"), sample("b")), emptyMap(), false)
        job.cancelAndJoin()
        val nextJob = SupervisorJob()
        try {
            val restored = open(file, nextJob)
            assertEquals(1024.0, restored.snapshotFor("a")!!.networkBytesPerSecond!!, 0.0)
            assertEquals(2048.0, restored.snapshotFor("b")!!.diskBytesPerSecond!!, 0.0)
            val newSession = restored.beginSession()
            restored.synchronize(newSession, 1, servers, listOf(sample("a", MonitorStatus.notStarted, null)), emptyMap(), false)
            assertEquals(now, restored.snapshotFor("a")!!.sampledAt)
            assertEquals(MonitorStatus.notStarted, restored.snapshotFor("a")!!.status)
            assertFalse(restored.synchronize(session, 100, servers, listOf(sample("a")), emptyMap(), false))
        } finally { nextJob.cancelAndJoin() }
    }

    @Test fun staleSequenceDeletionResetAndConfigurationChangeCannotResurrectSamples() = runBlocking {
        val job = SupervisorJob()
        try {
            val repository = open(File(temporary.root, "ordered.bin"), job)
            val session = repository.beginSession()
            repository.synchronize(session, 1, servers, listOf(sample("a"), sample("b")), emptyMap(), false)
            repository.synchronize(session, 3, servers, listOf(sample("a", MonitorStatus.stopped)), emptyMap(), false)
            assertFalse(repository.synchronize(session, 2, servers, listOf(sample("a")), emptyMap(), false))
            assertEquals(MonitorStatus.stopped, repository.snapshotFor("a")!!.status)
            repository.synchronize(session, 4, servers.take(1), emptyList(), emptyMap(), false)
            assertNull(repository.snapshotFor("b"))
            repository.synchronize(session, 5, servers, emptyList(), mapOf("a" to now + 1), false)
            assertNull(repository.snapshotFor("a"))
            repository.synchronize(session, 6, servers, listOf(sample("a")), emptyMap(), false)
            repository.synchronize(session, 7, servers, emptyList(), emptyMap(), true)
            assertNull(repository.snapshotFor("a"))
            assertEquals(servers, repository.servers())
        } finally { job.cancelAndJoin() }
    }

    @Test fun corruptOrUnavailableStorageReadsAsSafeNoDataAndWritesReportFailure() = runBlocking {
        val job = SupervisorJob()
        try {
            val broken = File(temporary.root, "broken.bin").apply { writeText("invalid fixture") }
            val repository = open(broken, job)
            assertNull(repository.snapshotFor("a"))
            assertTrue(repository.servers().isEmpty())
            val directory = temporary.newFolder("directory")
            val unavailable = open(directory, job)
            assertNull(unavailable.snapshotFor("a"))
            assertTrue(unavailable.servers().isEmpty())
            try { unavailable.beginSession(); fail("write must fail") } catch (_: java.io.IOException) { }
        } finally { job.cancelAndJoin() }
    }

    @Test fun oversizedAndDuplicateDirectoriesAreRejectedAtomically() = runBlocking {
        val job = SupervisorJob()
        try {
            val repository = open(File(temporary.root, "bounded.bin"), job)
            val session = repository.beginSession()
            for (directory in listOf(List(101) { WidgetServer("id-$it", "Node") }, servers + servers.first())) {
                try { repository.synchronize(session, 1, directory, emptyList(), emptyMap(), false); fail("must reject") }
                catch (_: IllegalArgumentException) { }
            }
            assertTrue(repository.servers().isEmpty())
        } finally { job.cancelAndJoin() }
    }

    @Test fun sessionRestartExpiryAndUnknownValuesKeepAbsoluteSampleTime() = runBlocking {
        val job = SupervisorJob()
        try {
            val repository = open(File(temporary.root, "states.bin"), job)
            val session = repository.beginSession()
            repository.synchronize(WidgetWrite(session, 1, servers, listOf(sample("a", time = now - 60000)), emptyMap(), false))
            assertEquals(MonitorStatus.stale, repository.snapshotFor("a")!!.status)
            assertEquals(now - 60000, repository.snapshotFor("a")!!.sampledAt)
            assertNull(repository.snapshotFor("bad@id"))
            val nextSession = repository.beginSession()
            assertEquals(MonitorStatus.stopped, repository.snapshotFor("a")!!.status)
            repository.synchronize(nextSession, 1, servers, listOf(sample("a", MonitorStatus.failed, null)), emptyMap(), false)
            assertEquals(now - 60000, repository.snapshotFor("a")!!.sampledAt)
            repository.synchronize(nextSession, 2, servers, listOf(sample("a", time = now - 1)), emptyMap(), false)
            repository.synchronize(nextSession, 3, servers, listOf(sample("a", time = now - 2)), mapOf("a" to now), false)
            assertNull(repository.snapshotFor("a")!!.sampledAt)
            assertEquals(MonitorStatus.notStarted, repository.snapshotFor("a")!!.status)
            repository.synchronize(nextSession, 4, servers, listOf(sample("a", MonitorStatus.waiting, null)), emptyMap(), false)
            repository.beginSession()
            assertEquals(MonitorStatus.stopped, repository.snapshotFor("a")!!.status)
        } finally { job.cancelAndJoin() }
    }

    @Test fun externalDirectoryMutationCannotCorruptStoredCatalog() = runBlocking {
        val job = SupervisorJob()
        try {
            val repository = open(File(temporary.root, "isolated.bin"), job)
            val session = repository.beginSession()
            repository.synchronize(session, 1, servers, emptyList(), emptyMap(), false)
            val borrowed = repository.servers()
            try { (borrowed as MutableList<WidgetServer>).clear() } catch (_: UnsupportedOperationException) { }
            assertEquals(servers, repository.servers())
        } finally { job.cancelAndJoin() }
    }
}
