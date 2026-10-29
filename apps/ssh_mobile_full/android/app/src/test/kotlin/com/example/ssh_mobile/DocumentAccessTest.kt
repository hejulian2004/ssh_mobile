package com.example.ssh_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

class DocumentAccessTest {
    @Test
    fun anotherPickAndPickerCancellationPreserveAllLiveGrants() {
        val host = Host()
        val book = DocumentGrantBook(host)
        book.recordPickerResult("content://first")
        assertTrue(book.persist("content://first", DocumentAccessMode.Read))
        book.recordPickerResult("content://second")
        assertTrue(book.persist("content://second", DocumentAccessMode.Read))
        book.recordPickerResult(null)
        assertTrue(book.allows("content://first", DocumentAccessMode.Read))
        assertTrue(book.allows("content://second", DocumentAccessMode.Read))
        book.release("content://first", DocumentAccessMode.Read)
        assertFalse(book.allows("content://first", DocumentAccessMode.Read))
        assertTrue(book.allows("content://second", DocumentAccessMode.Read))
        book.release("content://second", DocumentAccessMode.Read)
        assertTrue(host.held.isEmpty())
    }

    @Test
    fun repeatedPickOfSameUriDoesNotReleaseTheOtherBorrower() {
        val host = Host()
        val book = DocumentGrantBook(host)
        repeat(2) {
            book.recordPickerResult("content://same")
            assertTrue(book.persist("content://same", DocumentAccessMode.Read))
        }
        book.release("content://same", DocumentAccessMode.Read)
        assertTrue(book.allows("content://same", DocumentAccessMode.Read))
        book.release("content://same", DocumentAccessMode.Read)
        assertFalse(book.allows("content://same", DocumentAccessMode.Read))
        assertEquals(1, host.events.count { it.startsWith("take:") })
        assertEquals(1, host.events.count { it.startsWith("release:") })
    }

    @Test
    fun openAndCreateUseDifferentActionsAndPersistableFlags() {
        val open = DocumentAccessDecision.request(
            DocumentAccessMode.Read,
            "image/*",
            "ignored.png",
        )
        assertEquals(DocumentAccessDecision.OPEN_DOCUMENT, open.action)
        assertEquals(DocumentAccessDecision.OPENABLE, open.category)
        assertEquals("image/*", open.mimeType)
        assertNull(open.suggestedName)
        assertEquals(DocumentAccessDecision.READ, open.persistableFlag)
        assertEquals(
            DocumentAccessDecision.READ or DocumentAccessDecision.PERSISTABLE,
            open.intentFlags,
        )

        val create = DocumentAccessDecision.request(
            DocumentAccessMode.Write,
            "application/octet-stream",
            "notes.txt",
        )
        assertEquals(DocumentAccessDecision.CREATE_DOCUMENT, create.action)
        assertEquals(DocumentAccessDecision.OPENABLE, create.category)
        assertEquals("notes.txt", create.suggestedName)
        assertEquals(DocumentAccessDecision.WRITE, create.persistableFlag)
        assertEquals(
            DocumentAccessDecision.WRITE or DocumentAccessDecision.PERSISTABLE,
            create.intentFlags,
        )
        assertEquals(1, DocumentAccessDecision.READ)
        assertEquals(2, DocumentAccessDecision.WRITE)
        assertEquals(0x40, DocumentAccessDecision.PERSISTABLE)
    }

    @Test
    fun persistAndReleaseCoverOnlyThePickerResultAndRequestedMode() {
        val host = Host()
        val book = DocumentGrantBook(host)
        book.recordPickerResult(null)
        assertFalse(book.persist("content://picked", DocumentAccessMode.Read))
        assertTrue(host.events.isEmpty())

        book.recordPickerResult("content://picked")
        assertFalse(book.persist("content://other", DocumentAccessMode.Read))
        assertTrue(host.events.isEmpty())
        assertFalse(book.allows("content://other", DocumentAccessMode.Read))

        assertTrue(book.persist("content://picked", DocumentAccessMode.Read))
        assertEquals(listOf("take:content://picked:1"), host.events)
        assertTrue(book.allows("content://picked", DocumentAccessMode.Read))
        assertFalse(book.allows("content://picked", DocumentAccessMode.Write))

        host.held["content://picked"] = 0
        assertFalse(book.allows("content://picked", DocumentAccessMode.Read))

        host.held["content://picked"] = DocumentAccessDecision.READ
        book.release("content://picked", DocumentAccessMode.Read)
        assertEquals(
            listOf("take:content://picked:1", "release:content://picked:1"),
            host.events,
        )
        assertFalse(book.allows("content://picked", DocumentAccessMode.Read))

        val writeHost = Host()
        val writeBook = DocumentGrantBook(writeHost)
        writeBook.recordPickerResult("content://saved", DocumentAccessMode.Write, 2 or 0x40)
        assertTrue(writeBook.persist("content://saved", DocumentAccessMode.Write))
        assertEquals(listOf("take:content://saved:2"), writeHost.events)
        assertTrue(writeBook.allows("content://saved", DocumentAccessMode.Write))
        assertFalse(writeBook.allows("content://saved", DocumentAccessMode.Read))
        writeBook.release("content://saved", DocumentAccessMode.Write)
        assertEquals(
            listOf("take:content://saved:2", "release:content://saved:2"),
            writeHost.events,
        )
        assertFalse(writeBook.allows("content://saved", DocumentAccessMode.Write))
    }

    @Test
    fun onlyReturnedModeIsAllowedAndTransientGrantsDoNotPersist() {
        val host = Host()
        val book = DocumentGrantBook(host)
        book.recordPickerResult("content://picked", DocumentAccessMode.Read, 1)
        assertFalse(book.persist("content://picked", DocumentAccessMode.Write))
        assertTrue(book.persist("content://picked", DocumentAccessMode.Read))
        assertFalse(book.persist("content://picked", DocumentAccessMode.Read))
        assertTrue(book.allows("content://picked", DocumentAccessMode.Read))
        assertTrue(host.events.isEmpty())
        book.release("content://picked", DocumentAccessMode.Write)
        assertTrue(book.allows("content://picked", DocumentAccessMode.Read))
        book.release("content://picked", DocumentAccessMode.Read)
        assertFalse(book.allows("content://picked", DocumentAccessMode.Read))
        assertTrue(host.events.isEmpty())

        book.recordPickerResult("content://denied", DocumentAccessMode.Read, 2 or 0x40)
        assertFalse(book.persist("content://denied", DocumentAccessMode.Read))
        assertFalse(book.allows("content://denied", DocumentAccessMode.Read))
    }

    @Test
    fun differentModesReleaseIndependentlyAndExistingGrantsRemainOwnedByTheirOwner() {
        val host = Host()
        host.held["content://prior"] = 1
        val book = DocumentGrantBook(host)
        book.recordPickerResult("content://prior")
        assertTrue(book.persist("content://prior", DocumentAccessMode.Read))
        assertTrue(host.events.isEmpty())
        book.recordPickerResult("content://prior", DocumentAccessMode.Write, 2 or 0x40)
        assertTrue(book.persist("content://prior", DocumentAccessMode.Write))
        book.release("content://prior", DocumentAccessMode.Read)
        assertTrue(book.allows("content://prior", DocumentAccessMode.Write))
        assertEquals(3, host.held["content://prior"])
        book.close()
        assertEquals(1, host.held["content://prior"])
        assertFalse(book.allows("content://prior", DocumentAccessMode.Write))
        book.close()
        assertEquals(listOf("take:content://prior:2", "release:content://prior:2"), host.events)
    }

    @Test
    fun closeReleasesAllOwnedGrantsEvenWhenOneWasRevoked() {
        val host = Host()
        val book = DocumentGrantBook(host)
        for (uri in listOf("content://revoked", "content://live")) {
            book.recordPickerResult(uri)
            book.persist(uri, DocumentAccessMode.Read)
        }
        host.failRelease = "content://revoked"
        book.close()
        assertFalse(book.allows("content://revoked", DocumentAccessMode.Read))
        assertFalse(book.allows("content://live", DocumentAccessMode.Read))
        assertEquals(listOf("content://revoked", "content://live"), host.events.filter { it.startsWith("release:") }.map { it.removePrefix("release:").removeSuffix(":1") })
    }

    @Test
    fun takeFailureCannotMintALeaseAndDefaultsAreOpenable() {
        val host = Host()
        host.failTake = true
        val book = DocumentGrantBook(host)
        book.recordPickerResult("content://denied")
        try {
            book.persist("content://denied", DocumentAccessMode.Read)
            throw AssertionError("expected security error")
        } catch (_: SecurityException) { }
        assertFalse(book.allows("content://denied", DocumentAccessMode.Read))
        assertFalse(book.persist("content://denied", DocumentAccessMode.Read))
        val request = DocumentAccessDecision.request(DocumentAccessMode.Write, "", "")
        assertEquals("*/*", request.mimeType)
        assertEquals("download", request.suggestedName)
    }

    @Test
    fun chunkedCopyFailureIsNotSuccessAndDropsThePartialFile() {
        val copy = BoundedChunkCopy(8)
        val directory = java.nio.file.Files.createTempDirectory("document-access").toFile()
        val cache = DocumentCacheFiles(directory)
        val partial = cache.reserve()
        val failed = FileOutputStream(partial).use { output ->
            copy.transfer(FailAfterChunks(chunks = 3, chunkSize = 8), output, maxBytes = 1024)
        }
        assertEquals(CopyOutcome.Failed, failed)
        assertTrue(partial.length() > 8L)
        cache.discard(partial)
        assertFalse(partial.exists())

        val kept = cache.reserve()
        val completed = FileOutputStream(kept).use { output ->
            copy.transfer(ByteArrayInputStream(ByteArray(20) { it.toByte() }), output, 1024)
        }
        assertEquals(CopyOutcome.Completed, completed)
        assertEquals(20L, kept.length())

        val rejected = copy.transfer(
            ByteArrayInputStream(ByteArray(30)),
            DiscardOutput(),
            maxBytes = 16,
        )
        assertEquals(CopyOutcome.Rejected, rejected)

        var opened = 0
        val denied = DocumentUriTransfer.import(
            grants = DocumentGrantBook(Host()),
            uri = "content://picked",
            openRead = {
                opened += 1
                ByteArrayInputStream(byteArrayOf(1))
            },
            output = DiscardOutput(),
            maxBytes = 100,
            copy = copy,
        )
        assertEquals(CopyOutcome.Denied, denied)
        assertEquals(0, opened)

        val host = Host()
        val book = DocumentGrantBook(host)
        book.recordPickerResult("content://picked")
        book.persist("content://picked", DocumentAccessMode.Read)
        val failedImport = DocumentUriTransfer.import(
            grants = book,
            uri = "content://picked",
            openRead = {
                opened += 1
                FailAfterChunks(chunks = 2, chunkSize = 8)
            },
            output = DiscardOutput(),
            maxBytes = 100,
            copy = copy,
        )
        assertEquals(CopyOutcome.Failed, failedImport)
        assertEquals(1, opened)
        cache.close()
        directory.deleteRecursively()
    }

    private class Host : DocumentGrantHost {
        val events = mutableListOf<String>()
        val held = mutableMapOf<String, Int>()
        var failTake = false
        var failRelease: String? = null

        override fun take(uri: String, flag: Int) {
            if (failTake) throw SecurityException()
            events += "take:$uri:$flag"
            held[uri] = (held[uri] ?: 0) or flag
        }

        override fun release(uri: String, flag: Int) {
            events += "release:$uri:$flag"
            if (uri == failRelease) throw SecurityException()
            val remaining = (held[uri] ?: 0) and flag.inv()
            if (remaining == 0) held.remove(uri) else held[uri] = remaining
        }

        override fun heldFlags(uri: String): Int = held[uri] ?: 0
    }

    private class FailAfterChunks(
        private val chunks: Int,
        private val chunkSize: Int,
    ) : InputStream() {
        private var served = 0

        override fun read(): Int = throw IOException("single-byte read is not used")

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (served >= chunks) throw IOException("mid-stream")
            val count = minOf(length, chunkSize)
            served += 1
            return count
        }
    }

    private class DiscardOutput : OutputStream() {
        override fun write(value: Int) = Unit
        override fun write(buffer: ByteArray, offset: Int, length: Int) = Unit
    }
}
