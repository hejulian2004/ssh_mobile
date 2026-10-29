package com.example.ssh_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID

/**
 * Storage Access Framework bridge for one activity.
 *
 * FlutterActivity is an Activity, so the picker result comes back through
 * onActivityResult. Grant checks and byte copies go through DocumentAccess.
 */
internal class DocumentAccessSession(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val grants = DocumentGrantBook(ResolverGrantHost(activity))
    private val copy = BoundedChunkCopy(CHUNK_BYTES)
    private val cache = DocumentCacheFiles(File(activity.cacheDir, CACHE_DIRECTORY))
    private val cancellations = DocumentCopyCancellation()
    private val nativeCopies = ConcurrentHashMap<String, NativeCopy>()
    private val cancellationExecutor = Executors.newCachedThreadPool()
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingMode = DocumentAccessMode.Read
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "pick" -> pick(args, result)
                "release" -> release(args, result)
                "copyToCache" -> copyToCache(args, result)
                "cancelCopy" -> {
                    (args?.get("operationId") as? String)?.let {
                        cancellations.cancel(it)
                        nativeCopies[it]?.let(::cancelNative)
                    }
                    result.success(true)
                }
                "reserveStaging" -> reserveStaging(result)
                "copyFromCache" -> copyFromCache(args, result)
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val waiting = pending
        pending = null
        if (waiting == null || disposed) return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            waiting.success(null)
            return true
        }
        if (uri.scheme != "content") {
            waiting.error(DENIED, "Only a content document can be used.", null)
            return true
        }
        val text = uri.toString()
        val mode = pendingMode
        val flags = data?.flags ?: 0
        runCopy(waiting) {
            grants.recordPickerResult(text, mode, flags)
            if (!grants.persist(text, mode)) {
                return@runCopy CopyPayload.Err(DENIED, "The document grant does not allow this use.")
            }
            try {
                val meta = queryMeta(uri)
                val payload = hashMapOf<String, Any?>(
                    "uri" to text,
                    "mode" to if (mode == DocumentAccessMode.Read) "read" else "write",
                    "displayName" to meta.first,
                )
                meta.second?.let { payload["size"] = it }
                if (disposed) {
                    grants.release(text, mode)
                    CopyPayload.Err(IO, "Document access ended.")
                } else {
                    CopyPayload.Ok(payload)
                }
            } catch (error: Exception) {
                try { grants.release(text, mode) } catch (_: Exception) { }
                throw error
            }
        }
        return true
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        cancellations.close()
        nativeCopies.values.forEach(::cancelNative)
        cancellationExecutor.shutdown()
        channel.setMethodCallHandler(null)
        val waiting = pending
        pending = null
        if (waiting != null) {
            try {
                waiting.success(null)
            } catch (_: RuntimeException) {
            }
        }
        // The running bounded copy observes disposed; queued operations report failure.
        // Cleanup remains on this serial worker after all streams have closed.
        executor.execute {
            try { grants.close() } finally { cache.close() }
        }
        executor.shutdown()
    }

    private fun pick(args: Map<*, *>?, result: MethodChannel.Result) {
        if (pending != null) {
            result.error(DENIED, "A document picker is already open.", null)
            return
        }
        val mode = modeOf(args?.get("mode"))
        if (mode == null) {
            result.error(DENIED, "Document mode is invalid.", null)
            return
        }
        val mime = args?.get("mimeType") as? String ?: "*/*"
        val suggested = args?.get("suggestedName") as? String
        val request = DocumentAccessDecision.request(mode, mime, suggested)
        val intent = Intent(request.action).apply {
            addCategory(request.category)
            type = request.mimeType
            if (request.suggestedName != null) {
                putExtra(Intent.EXTRA_TITLE, request.suggestedName)
            }
            addFlags(request.intentFlags)
        }
        pending = result
        pendingMode = mode
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            pending = null
            result.error(MISSING, "No document picker is available.", null)
        } catch (_: SecurityException) {
            pending = null
            result.error(DENIED, "The document picker is unavailable.", null)
        }
    }

    private fun release(args: Map<*, *>?, result: MethodChannel.Result) {
        val uri = args?.get("uri") as? String
        val mode = modeOf(args?.get("mode"))
        if (uri.isNullOrBlank() || mode == null) {
            result.error(DENIED, "Document grant is invalid.", null)
            return
        }
        runCopy(result) {
            grants.release(uri, mode)
            CopyPayload.Ok(true)
        }
    }

    private fun copyToCache(args: Map<*, *>?, result: MethodChannel.Result) {
        val uri = args?.get("uri") as? String
        val maxBytes = (args?.get("maxBytes") as? Number)?.toLong()
        val operationId = args?.get("operationId") as? String ?: UUID.randomUUID().toString()
        if (uri.isNullOrBlank() || maxBytes == null || maxBytes < 0) {
            result.error(DENIED, "Document read is invalid.", null)
            return
        }
        if (operationId.isBlank() || operationId.length > 128 || !cancellations.begin(operationId)) {
            result.error(DENIED, "Document copy attempt is invalid.", null)
            return
        }
        val native = NativeCopy().also { nativeCopies[operationId] = it }
        runCopy(result, copyId = operationId, onFinished = { cancellations.finish(operationId); nativeCopies.remove(operationId) }) {
            val file = cache.reserve()
            var completed = false
            try {
                val outcome = file.outputStream().use { output ->
                    DocumentUriTransfer.import(
                        grants = grants,
                        uri = uri,
                        openRead = { openRead(uri, native) },
                        output = output,
                        maxBytes = maxBytes,
                        copy = copy,
                        isCancelled = { disposed || cancellations.isCancelled(operationId) },
                    )
                }
                val finalOutcome = if (disposed || cancellations.isCancelled(operationId)) CopyOutcome.Cancelled else outcome
                completed = finalOutcome == CopyOutcome.Completed
                finalOutcome.toPayload(file)
            } finally {
                if (!completed) cache.discard(file)
            }
        }
    }

    private fun reserveStaging(result: MethodChannel.Result) {
        runCopy(result) {
            val file = cache.reserve()
            CopyPayload.Ok(mapOf("path" to file.absolutePath))
        }
    }

    private fun copyFromCache(args: Map<*, *>?, result: MethodChannel.Result) {
        val uri = args?.get("uri") as? String
        val path = args?.get("path") as? String
        val operationId = args?.get("operationId") as? String ?: UUID.randomUUID().toString()
        if (uri.isNullOrBlank() || path.isNullOrBlank()) {
            result.error(DENIED, "Document write is invalid.", null)
            return
        }
        if (operationId.isBlank() || operationId.length > 128 || !cancellations.begin(operationId)) {
            result.error(DENIED, "Document copy attempt is invalid.", null)
            return
        }
        val native = NativeCopy().also { nativeCopies[operationId] = it }
        runCopy(result, copyId = operationId, onFinished = { cancellations.finish(operationId); nativeCopies.remove(operationId) }) {
            val file = cache.resolve(path)
                ?: return@runCopy CopyPayload.Err(MISSING, "Document staging file is missing.")
            val outcome = file.inputStream().use { input ->
                DocumentUriTransfer.export(
                    grants = grants,
                    uri = uri,
                    input = input,
                    openWrite = { openWrite(uri, native) },
                    maxBytes = file.length(),
                    copy = copy,
                    isCancelled = { disposed || cancellations.isCancelled(operationId) },
                )
            }
            if (disposed || cancellations.isCancelled(operationId)) {
                CopyOutcome.Cancelled.toPayload(file)
            } else {
                outcome.toPayload(file)
            }
        }
    }

    private fun openRead(uri: String, native: NativeCopy): InputStream {
        return DocumentUriTransfer.open {
            val descriptor = activity.contentResolver.openFileDescriptor(Uri.parse(uri), "r", native.signal)
                ?: throw FileNotFoundException("missing")
            native.attach(descriptor)
            ParcelFileDescriptor.AutoCloseInputStream(descriptor)
        }
    }

    private fun openWrite(uri: String, native: NativeCopy): OutputStream {
        return DocumentUriTransfer.open {
            val descriptor = activity.contentResolver.openFileDescriptor(Uri.parse(uri), "wt", native.signal)
                ?: throw FileNotFoundException("missing")
            native.attach(descriptor)
            ParcelFileDescriptor.AutoCloseOutputStream(descriptor)
        }
    }

    private fun runCopy(result: MethodChannel.Result, copyId: String? = null, onFinished: () -> Unit = {}, block: () -> CopyPayload) {
        if (disposed) {
            onFinished()
            result.error(IO, "Document access ended.", null)
            return
        }
        executor.execute {
            val payload = try {
                if (disposed) CopyPayload.Err(IO, "Document access ended.") else block()
            } catch (_: SecurityException) {
                if (copyId != null && cancellations.isCancelled(copyId)) {
                    CopyPayload.Err(CANCELLED, "Document copy was cancelled.")
                } else CopyPayload.Err(DENIED, "Document access was revoked.")
            } catch (_: OperationCanceledException) {
                CopyPayload.Err(CANCELLED, "Document copy was cancelled.")
            } catch (_: Exception) {
                if (copyId != null && cancellations.isCancelled(copyId)) {
                    CopyPayload.Err(CANCELLED, "Document copy was cancelled.")
                } else CopyPayload.Err(IO, "Document copy failed.")
            } finally {
                onFinished()
            }
            main.post {
                try {
                    when {
                        disposed -> result.error(IO, "Document access ended.", null)
                        payload is CopyPayload.Ok -> result.success(payload.value)
                        payload is CopyPayload.Err -> result.error(payload.code, payload.message, null)
                    }
                } catch (_: RuntimeException) {
                }
            }
        }
    }

    private fun cancelNative(native: NativeCopy) {
        cancellationExecutor.execute {
            try { native.signal.cancel() } catch (_: Exception) { } finally {
                try { native.descriptor?.close() } catch (_: Exception) { }
            }
        }
    }

    private class NativeCopy {
        val signal = CancellationSignal()
        @Volatile var descriptor: ParcelFileDescriptor? = null
        fun attach(value: ParcelFileDescriptor) {
            descriptor = value
            if (signal.isCanceled) {
                value.close()
                throw OperationCanceledException()
            }
        }
    }

    private fun queryMeta(uri: Uri): Pair<String?, Long?> {
        val cursor = activity.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        ) ?: return null to null
        cursor.use {
            if (!it.moveToFirst()) return null to null
            val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = it.getColumnIndex(OpenableColumns.SIZE)
            val name = if (nameIndex >= 0 && !it.isNull(nameIndex)) it.getString(nameIndex) else null
            val size = if (sizeIndex >= 0 && !it.isNull(sizeIndex)) it.getLong(sizeIndex) else null
            return name to size?.takeIf { value -> value >= 0L }
        }
    }

    private fun modeOf(value: Any?): DocumentAccessMode? = when (value) {
        "read" -> DocumentAccessMode.Read
        "write" -> DocumentAccessMode.Write
        else -> null
    }

    private fun CopyOutcome.toPayload(file: File): CopyPayload = when (this) {
        CopyOutcome.Completed -> CopyPayload.Ok(
            mapOf("path" to file.absolutePath, "size" to file.length()),
        )
        CopyOutcome.Rejected -> CopyPayload.Err(TOO_LARGE, "Document is larger than the limit.")
        CopyOutcome.Denied -> CopyPayload.Err(DENIED, "Document grant does not allow this use.")
        CopyOutcome.Missing -> CopyPayload.Err(MISSING, "Document is missing.")
        CopyOutcome.Failed -> CopyPayload.Err(IO, "Document copy failed.")
        CopyOutcome.Cancelled -> CopyPayload.Err(CANCELLED, "Document copy was cancelled.")
    }

    private sealed class CopyPayload {
        class Ok(val value: Any?) : CopyPayload()
        class Err(val code: String, val message: String) : CopyPayload()
    }

    private class ResolverGrantHost(private val activity: Activity) : DocumentGrantHost {
        override fun take(uri: String, flag: Int) {
            activity.contentResolver.takePersistableUriPermission(Uri.parse(uri), flag)
        }

        override fun release(uri: String, flag: Int) {
            activity.contentResolver.releasePersistableUriPermission(Uri.parse(uri), flag)
        }

        override fun heldFlags(uri: String): Int {
            val parsed = Uri.parse(uri)
            var flags = 0
            for (permission in activity.contentResolver.persistedUriPermissions) {
                if (permission.uri != parsed) continue
                if (permission.isReadPermission) flags = flags or DocumentAccessDecision.READ
                if (permission.isWritePermission) flags = flags or DocumentAccessDecision.WRITE
            }
            return flags
        }
    }

    companion object {
        const val CHANNEL = "ssh_mobile/document_access"
        private const val REQUEST_CODE = 0x53A7
        private const val CHUNK_BYTES = 16 * 1024
        private const val CACHE_DIRECTORY = "document-access"
        private const val DENIED = "DOCUMENT_DENIED"
        private const val MISSING = "DOCUMENT_MISSING"
        private const val TOO_LARGE = "DOCUMENT_TOO_LARGE"
        private const val IO = "DOCUMENT_IO"
        private const val CANCELLED = "DOCUMENT_CANCELLED"
    }
}
