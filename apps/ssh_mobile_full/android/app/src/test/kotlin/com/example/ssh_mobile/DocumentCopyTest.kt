package com.example.ssh_mobile

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import org.junit.Assert.*
import org.junit.Test

class DocumentCopyTest {
    @Test
    fun cancellingOneAttemptDoesNotCancelAnotherAndLateAttemptReuseIsIndependent() {
        val cancellations = DocumentCopyCancellation()
        assertTrue(cancellations.begin("first"))
        assertFalse(cancellations.begin("first"))
        assertTrue(cancellations.begin("second"))
        cancellations.cancel("first")
        assertTrue(cancellations.isCancelled("first"))
        assertFalse(cancellations.isCancelled("second"))
        cancellations.cancel("unknown")
        cancellations.finish("first")
        assertTrue(cancellations.isCancelled("first"))
        assertTrue(cancellations.begin("first"))
        assertFalse(cancellations.isCancelled("first"))
        cancellations.close()
        assertTrue(cancellations.isCancelled("first"))
        assertTrue(cancellations.isCancelled("second"))
    }

    @Test
    fun limitsUseASingleSentinelAndAllowExactSizeAndEmptyDocuments() {
        val input = ByteArrayInputStream(ByteArray(100))
        val output = ByteArrayOutputStream()
        assertEquals(CopyOutcome.Rejected, BoundedChunkCopy(16).transfer(input, output, 20))
        assertEquals(79, input.available())
        assertEquals(16, output.size())
        assertEquals(CopyOutcome.Completed, BoundedChunkCopy(16).transfer(ByteArrayInputStream(ByteArray(20)), ByteArrayOutputStream(), 20))
        assertEquals(CopyOutcome.Completed, BoundedChunkCopy(16).transfer(ByteArrayInputStream(byteArrayOf()), ByteArrayOutputStream(), 0))
        assertEquals(CopyOutcome.Completed, BoundedChunkCopy(16).transfer(ByteArrayInputStream(byteArrayOf(1)), ByteArrayOutputStream(), Long.MAX_VALUE))
        assertEquals(CopyOutcome.Rejected, BoundedChunkCopy(16).transfer(ByteArrayInputStream(byteArrayOf(1)), ByteArrayOutputStream(), -1))
    }

    @Test
    fun cancellationNeverPublishesAnotherChunkAndZeroReadsDoNotSpin() {
        var writes = 0
        val output = object : OutputStream() {
            override fun write(value: Int) { writes++ }
        }
        assertEquals(CopyOutcome.Cancelled, BoundedChunkCopy(8).transfer(ByteArrayInputStream(ByteArray(20)), output, 100) { true })
        assertEquals(0, writes)
        var cancelled = false
        val input = object : ByteArrayInputStream(ByteArray(8)) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                cancelled = true
                return super.read(bytes, offset, length)
            }
        }
        assertEquals(CopyOutcome.Cancelled, BoundedChunkCopy(8).transfer(input, output, 100) { cancelled })
        assertEquals(0, writes)
        val stalled = object : InputStream() {
            override fun read() = 0
            override fun read(bytes: ByteArray, offset: Int, length: Int) = 0
        }
        assertEquals(CopyOutcome.Failed, BoundedChunkCopy(8).transfer(stalled, output, 100))
        Thread.currentThread().interrupt()
        try {
            assertEquals(CopyOutcome.Cancelled, BoundedChunkCopy(8).transfer(ByteArrayInputStream(ByteArray(8)), output, 100))
        } finally {
            Thread.interrupted()
        }
    }

    @Test
    fun openAndCloseFailuresAreTypedAndNoCopyReportsSuccess() {
        val copy = BoundedChunkCopy(8)
        val denied = try {
            DocumentUriTransfer.open<InputStream> { throw SecurityException() }
            throw AssertionError("expected denial")
        } catch (error: DocumentStreamException) { error.outcome }
        assertEquals(CopyOutcome.Denied, denied)
        val missing = try {
            DocumentUriTransfer.open<InputStream> { throw FileNotFoundException() }
            throw AssertionError("expected missing document")
        } catch (error: DocumentStreamException) { error.outcome }
        assertEquals(CopyOutcome.Missing, missing)
        assertEquals("opened", DocumentUriTransfer.open { "opened" })

        val readBook = book(DocumentAccessMode.Read)
        assertEquals(CopyOutcome.Missing, DocumentUriTransfer.import(readBook, URI, { throw DocumentStreamException(CopyOutcome.Missing) }, ByteArrayOutputStream(), 100, copy))
        val input = object : ByteArrayInputStream(byteArrayOf(1, 2, 3)) {
            override fun close() { throw IOException() }
        }
        assertEquals(CopyOutcome.Failed, DocumentUriTransfer.import(readBook, URI, { input }, ByteArrayOutputStream(), 100, copy))

        var opened = false
        assertEquals(CopyOutcome.Denied, DocumentUriTransfer.export(readBook, URI, ByteArrayInputStream(byteArrayOf(1)), { opened = true; ByteArrayOutputStream() }, 100, copy))
        assertFalse(opened)
        val writeBook = book(DocumentAccessMode.Write)
        assertEquals(CopyOutcome.Denied, DocumentUriTransfer.export(writeBook, URI, ByteArrayInputStream(byteArrayOf()), { throw DocumentStreamException(CopyOutcome.Denied) }, 100, copy))
        val bytes = ByteArrayOutputStream()
        assertEquals(CopyOutcome.Completed, DocumentUriTransfer.export(writeBook, URI, ByteArrayInputStream(byteArrayOf(1, 2, 3)), { bytes }, 100, copy))
        assertArrayEquals(byteArrayOf(1, 2, 3), bytes.toByteArray())
        val failingClose = object : ByteArrayOutputStream() {
            override fun close() { throw IOException() }
        }
        assertEquals(CopyOutcome.Failed, DocumentUriTransfer.export(writeBook, URI, ByteArrayInputStream(byteArrayOf(1)), { failingClose }, 100, copy))
        val failingOutput = object : OutputStream() {
            override fun write(value: Int) { throw IOException() }
        }
        assertEquals(CopyOutcome.Failed, copy.transfer(ByteArrayInputStream(byteArrayOf(1)), failingOutput, 100))
        try {
            BoundedChunkCopy(0)
            throw AssertionError("expected chunk validation")
        } catch (_: IllegalArgumentException) { }
    }

    private fun book(mode: DocumentAccessMode): DocumentGrantBook {
        val flag = DocumentAccessDecision.flag(mode)
        val book = DocumentGrantBook(object : DocumentGrantHost {
            override fun take(uri: String, flag: Int) = Unit
            override fun release(uri: String, flag: Int) = Unit
            override fun heldFlags(uri: String) = 0
        })
        book.recordPickerResult(URI, mode, flag)
        assertTrue(book.persist(URI, mode))
        return book
    }

    companion object { private const val URI = "content://fixture/document" }
}
