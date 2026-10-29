package com.example.ssh_mobile

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Read opens an existing document. Write creates one save target. */
internal enum class DocumentAccessMode { Read, Write }

/**
 * Picker choices that do not load Android framework types.
 *
 * Take and release use only [READ] or [WRITE]. The intent also carries
 * [PERSISTABLE], which is not a persistable-permission mode flag.
 */
internal object DocumentAccessDecision {
    const val OPEN_DOCUMENT = "android.intent.action.OPEN_DOCUMENT"
    const val CREATE_DOCUMENT = "android.intent.action.CREATE_DOCUMENT"
    const val OPENABLE = "android.intent.category.OPENABLE"
    const val READ = 1
    const val WRITE = 2
    const val PERSISTABLE = 0x40

    fun request(
        mode: DocumentAccessMode,
        mimeType: String,
        suggestedName: String?,
    ): DocumentRequest {
        val mime = mimeType.ifBlank { "*/*" }
        return when (mode) {
            DocumentAccessMode.Read -> DocumentRequest(
                action = OPEN_DOCUMENT,
                category = OPENABLE,
                mimeType = mime,
                suggestedName = null,
                intentFlags = READ or PERSISTABLE,
                persistableFlag = READ,
            )
            DocumentAccessMode.Write -> DocumentRequest(
                action = CREATE_DOCUMENT,
                category = OPENABLE,
                mimeType = mime,
                suggestedName = suggestedName?.takeIf { it.isNotBlank() } ?: "download",
                intentFlags = WRITE or PERSISTABLE,
                persistableFlag = WRITE,
            )
        }
    }

    fun flag(mode: DocumentAccessMode): Int = when (mode) {
        DocumentAccessMode.Read -> READ
        DocumentAccessMode.Write -> WRITE
    }
}

internal data class DocumentRequest(
    val action: String,
    val category: String,
    val mimeType: String,
    val suggestedName: String?,
    val intentFlags: Int,
    val persistableFlag: Int,
)

internal interface DocumentGrantHost {
    fun take(uri: String, flag: Int)
    fun release(uri: String, flag: Int)
    fun heldFlags(uri: String): Int
}

/**
 * Each successful picker result adds one URI/mode lease. Cancelling a later
 * picker cannot invalidate earlier leases. Only grants acquired here are released.
 */
internal class DocumentGrantBook(private val host: DocumentGrantHost) {
    private data class Key(val uri: String, val mode: DocumentAccessMode)
    private data class Lease(var count: Int, val persistent: Boolean, val owned: Boolean)
    private data class Pick(val uri: String, val mode: DocumentAccessMode, val flags: Int)
    private val leases = mutableMapOf<Key, Lease>()
    private var picked: Pick? = null

    @Synchronized
    fun recordPickerResult(
        uri: String?,
        mode: DocumentAccessMode = DocumentAccessMode.Read,
        flags: Int = DocumentAccessDecision.READ or DocumentAccessDecision.PERSISTABLE,
    ) {
        picked = uri?.let { Pick(it, mode, flags) }
    }

    @Synchronized
    fun persist(uri: String, mode: DocumentAccessMode): Boolean {
        val result = picked ?: return false
        val flag = DocumentAccessDecision.flag(mode)
        if (uri != result.uri || mode != result.mode || result.flags and flag == 0) return false
        picked = null // A picker result can mint only one lease.
        val key = Key(uri, mode)
        val existing = leases[key]
        if (existing != null) {
            if (!allows(uri, mode)) return false
            existing.count++
            return true
        }
        val persistent = result.flags and DocumentAccessDecision.PERSISTABLE != 0
        val owned = persistent && host.heldFlags(uri) and flag == 0
        if (owned) host.take(uri, flag)
        leases[key] = Lease(1, persistent, owned)
        return true
    }

    @Synchronized
    fun release(uri: String, mode: DocumentAccessMode) {
        val key = Key(uri, mode)
        val lease = leases[key] ?: return
        if (lease.count > 1) {
            lease.count--
            return
        }
        if (lease.owned) host.release(uri, DocumentAccessDecision.flag(mode))
        leases.remove(key)
    }

    @Synchronized
    fun allows(uri: String, mode: DocumentAccessMode): Boolean {
        val lease = leases[Key(uri, mode)] ?: return false
        return !lease.persistent || host.heldFlags(uri) and DocumentAccessDecision.flag(mode) != 0
    }

    @Synchronized
    fun close() {
        picked = null
        for ((key, lease) in leases.toMap()) {
            try {
                if (lease.owned) host.release(key.uri, DocumentAccessDecision.flag(key.mode))
                leases.remove(key)
            } catch (_: SecurityException) {
                // A provider may already have revoked this grant. Other grants still release.
                leases.remove(key)
            }
        }
    }
}

internal enum class CopyOutcome { Completed, Failed, Rejected, Denied, Missing, Cancelled }

/** A cancellation belongs to one copy attempt, including while it is queued. */
internal class DocumentCopyCancellation {
    private val attempts = ConcurrentHashMap<String, AtomicBoolean>()

    fun begin(id: String): Boolean = attempts.putIfAbsent(id, AtomicBoolean(false)) == null
    fun cancel(id: String) { attempts[id]?.set(true) }
    fun isCancelled(id: String): Boolean = attempts[id]?.get() ?: true
    fun finish(id: String) { attempts.remove(id) }
    fun close() {
        attempts.values.forEach { it.set(true) }
        attempts.clear()
    }
}

/** Copies one stream in bounded chunks. An I/O error is never [CopyOutcome.Completed]. */
internal class BoundedChunkCopy(private val chunkSize: Int) {
    init {
        require(chunkSize > 0)
    }

    fun transfer(
        input: InputStream,
        output: OutputStream,
        maxBytes: Long,
        isCancelled: () -> Boolean = { false },
    ): CopyOutcome {
        if (maxBytes < 0L) return CopyOutcome.Rejected
        val buffer = ByteArray(chunkSize)
        var total = 0L
        try {
            while (true) {
                if (isCancelled() || Thread.currentThread().isInterrupted) return CopyOutcome.Cancelled
                val remaining = maxBytes - total
                val requested = if (remaining >= buffer.size) buffer.size else remaining.toInt() + 1
                val count = input.read(buffer, 0, requested)
                if (count < 0) break
                if (isCancelled()) return CopyOutcome.Cancelled
                if (count == 0) return CopyOutcome.Failed
                if (count.toLong() > maxBytes - total) return CopyOutcome.Rejected
                output.write(buffer, 0, count)
                total += count.toLong()
            }
            output.flush()
            return CopyOutcome.Completed
        } catch (_: IOException) {
            return CopyOutcome.Failed
        }
    }
}

/** Opens a stream only after the grant book allows that URI and mode. */
internal object DocumentUriTransfer {
    fun import(
        grants: DocumentGrantBook,
        uri: String,
        openRead: () -> InputStream,
        output: OutputStream,
        maxBytes: Long,
        copy: BoundedChunkCopy,
        isCancelled: () -> Boolean = { false },
    ): CopyOutcome {
        if (!grants.allows(uri, DocumentAccessMode.Read)) return CopyOutcome.Denied
        val input = try {
            openRead()
        } catch (error: DocumentStreamException) {
            return error.outcome
        }
        return try {
            input.use { copy.transfer(it, output, maxBytes, isCancelled) }
        } catch (_: IOException) {
            CopyOutcome.Failed
        }
    }

    fun export(
        grants: DocumentGrantBook,
        uri: String,
        input: InputStream,
        openWrite: () -> OutputStream,
        maxBytes: Long,
        copy: BoundedChunkCopy,
        isCancelled: () -> Boolean = { false },
    ): CopyOutcome {
        if (!grants.allows(uri, DocumentAccessMode.Write)) return CopyOutcome.Denied
        val output = try {
            openWrite()
        } catch (error: DocumentStreamException) {
            return error.outcome
        }
        return try {
            output.use { copy.transfer(input, it, maxBytes, isCancelled) }
        } catch (_: IOException) {
            CopyOutcome.Failed
        }
    }

    fun <T> open(open: () -> T): T {
        try {
            return open()
        } catch (_: SecurityException) {
            throw DocumentStreamException(CopyOutcome.Denied)
        } catch (_: IOException) {
            throw DocumentStreamException(CopyOutcome.Missing)
        }
    }
}

/** Files reserved by this Activity bridge; arbitrary cache files are never exportable. */
internal class DocumentCacheFiles(private val root: File) {
    private val owned = mutableMapOf<String, File>()
    private var directory: File? = null
    private var closed = false

    @Synchronized
    fun reserve(): File {
        check(!closed)
        val folder = directory ?: run {
            if (!root.isDirectory && !root.mkdirs()) throw IOException("cache unavailable")
            val reserved = File.createTempFile("session-", ".tmp", root)
            if (!reserved.delete() || !reserved.mkdir()) throw IOException("cache unavailable")
            reserved.also { directory = it }
        }
        val file = File.createTempFile("document-", ".bin", folder).canonicalFile
        owned[file.absolutePath] = file
        return file
    }

    @Synchronized
    fun resolve(path: String): File? {
        if (closed) return null
        val reserved = owned[path] ?: return null
        if (!reserved.isFile || reserved.canonicalFile != reserved) return null
        return reserved
    }

    @Synchronized
    fun discard(file: File) {
        if (owned.remove(file.absolutePath) != null) file.delete()
    }

    @Synchronized
    fun close() {
        closed = true
        owned.values.forEach { it.delete() }
        owned.clear()
        directory?.delete()
        directory = null
    }
}

internal class DocumentStreamException(val outcome: CopyOutcome) : Exception()
