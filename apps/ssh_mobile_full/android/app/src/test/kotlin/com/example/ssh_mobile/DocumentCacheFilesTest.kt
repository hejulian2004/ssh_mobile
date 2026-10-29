package com.example.ssh_mobile

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class DocumentCacheFilesTest {
    @Test
    fun onlyReservedUnmodifiedPathsCanBeExportedAndCloseDeletesOwnedFiles() {
        val root = Files.createTempDirectory("document-cache-test").toFile()
        try {
            val cache = DocumentCacheFiles(File(root, "cache"))
            val first = cache.reserve()
            val second = cache.reserve()
            assertNotEquals(first.path, second.path)
            first.writeText("public fixture")
            assertEquals(first, cache.resolve(first.absolutePath))
            val foreign = File(root, "foreign.bin").apply { writeText("keep") }
            assertNull(cache.resolve(foreign.absolutePath))
            assertNull(cache.resolve(File(first.parentFile, "../foreign.bin").absolutePath))
            cache.discard(foreign)
            assertEquals("keep", foreign.readText())
            cache.discard(first)
            assertFalse(first.exists())
            assertNull(cache.resolve(first.absolutePath))
            cache.close()
            assertFalse(second.exists())
            assertFalse(second.parentFile.exists())
            assertNull(cache.resolve(second.absolutePath))
            cache.close()
            try {
                cache.reserve()
                throw AssertionError("closed cache must not create another file")
            } catch (_: IllegalStateException) { }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun missingFileAndInvalidRootFailClosed() {
        val root = Files.createTempDirectory("document-cache-test").toFile()
        try {
            val blocker = File(root, "not-a-directory").apply { writeText("keep") }
            try {
                DocumentCacheFiles(blocker).reserve()
                throw AssertionError("cache root must be a directory")
            } catch (_: IOException) { }
            val cache = DocumentCacheFiles(root)
            val missing = cache.reserve()
            assertTrue(missing.delete())
            assertNull(cache.resolve(missing.path))
            cache.close()
            assertEquals("keep", blocker.readText())
        } finally {
            root.deleteRecursively()
        }
    }
}
