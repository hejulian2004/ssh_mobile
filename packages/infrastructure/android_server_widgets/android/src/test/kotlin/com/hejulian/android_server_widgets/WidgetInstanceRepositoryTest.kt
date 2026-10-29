package com.hejulian.android_server_widgets

import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WidgetInstanceRepositoryTest {
    @get:Rule val temp = TemporaryFolder()
    private fun open(file: File, job: kotlinx.coroutines.Job) = WidgetInstanceRepository(DataStoreFactory.create(
        serializer = WidgetInstancesSerializer,
        corruptionHandler = ReplaceFileCorruptionHandler { emptyMap() },
        scope = CoroutineScope(Dispatchers.IO + job), produceFile = { file },
    ))

    @Test fun instancesPersistIndependentlyAndDeletingOneDoesNotAffectTheOther() = runBlocking {
        val file = File(temp.root, "bindings.bin")
        val job = SupervisorJob()
        val first = open(file, job)
        first.configure(10, "server-a")
        first.configure(11, "server-b")
        first.configure(12, "server-a")
        first.removeWidgets(setOf(10))
        assertNull(first.connectionFor(10))
        assertEquals("server-b", first.connectionFor(11))
        assertEquals("server-a", first.connectionFor(12))
        job.cancelAndJoin()
        val nextJob = SupervisorJob()
        try {
            val next = open(file, nextJob)
            assertEquals(mapOf(11 to "server-b", 12 to "server-a"), next.mappings())
            val borrowed = next.mappings()
            try { (borrowed as MutableMap<Int, String>).clear() } catch (_: UnsupportedOperationException) { }
            assertEquals(2, next.mappings().size)
            next.restore(intArrayOf(11, 12), intArrayOf(21, 22))
            assertEquals(mapOf(21 to "server-b", 22 to "server-a"), next.mappings())
            next.clear()
            assertTrue(next.mappings().isEmpty())
        } finally { nextJob.cancelAndJoin() }
    }

    @Test fun invalidAndOversizedMappingsFailAtomicallyAndCorruptionIsSafe() = runBlocking {
        val job = SupervisorJob()
        try {
            val file = File(temp.root, "bad.bin").apply { writeText("invalid fixture") }
            val repository = open(file, job)
            assertNull(repository.connectionFor(-1))
            assertTrue(repository.mappings().isEmpty())
            for ((id, server) in listOf(0 to "a", -1 to "a", 1 to "bad@id")) {
                try { repository.configure(id, server); fail("must reject") } catch (_: IllegalArgumentException) { }
            }
            for (id in 1..100) repository.configure(id, "server-a")
            try { repository.configure(101, "server-b"); fail("must bound instances") } catch (_: IllegalArgumentException) { }
            assertEquals(100, repository.mappings().size)
            try { repository.restore(intArrayOf(1), intArrayOf(2, 3)); fail("mismatched restore") } catch (_: IllegalArgumentException) { }
            try { repository.restore(intArrayOf(1), intArrayOf(2)); fail("existing destination") } catch (_: IllegalArgumentException) { }
            assertEquals("server-a", repository.connectionFor(1))
        } finally { job.cancelAndJoin() }
    }

    @Test fun storageReadFailureIsNoDataWhileWritesStayFailures() = runBlocking {
        val job = SupervisorJob()
        try {
            val repository = open(temp.newFolder("not-file"), job)
            assertTrue(repository.mappings().isEmpty())
            try { repository.configure(1, "a"); fail("must report storage failure") } catch (_: java.io.IOException) { }
        } finally { job.cancelAndJoin() }
    }

    @Test fun partialRestoreKeepsUnrelatedSelectionsAndReconfigurationAtCapacityIsAllowed() = runBlocking {
        val store = object : androidx.datastore.core.DataStore<Map<Int, String>> {
            val state = MutableStateFlow((1..100).associateWith { "server-a" })
            override val data: kotlinx.coroutines.flow.Flow<Map<Int, String>> = state
            override suspend fun updateData(transform: suspend (Map<Int, String>) -> Map<Int, String>): Map<Int, String> =
                transform(state.value).also { state.value = it }
        }
        val repository = WidgetInstanceRepository(store)
        repository.configure(1, "server-b")
        assertEquals("server-b", repository.connectionFor(1))
        repository.removeWidgets(setOf(99, 100))
        repository.restore(intArrayOf(1, 101), intArrayOf(201, 202))
        assertEquals("server-b", repository.connectionFor(201))
        assertNull(repository.connectionFor(202))
        assertNull(repository.connectionFor(1))
        assertEquals("server-a", repository.connectionFor(2))
        repository.clear()
        assertTrue(repository.mappings().isEmpty())
    }
}
