package com.example.ssh_mobile

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Framework-only runner exercising the real ContentResolver and PFD provider. */
class DocumentAccessInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val report = Bundle()
        try {
            exerciseBridge()
            report.putString("stream", "SAF bridge: picker/cancel/read/write/limits/revocation/cleanup passed\n")
            finish(Activity.RESULT_OK, report)
        } catch (error: Throwable) {
            report.putString("stream", "SAF bridge failed: ${error.javaClass.simpleName}: ${error.message}\n")
            finish(Activity.RESULT_CANCELED, report)
        }
    }

    private fun exerciseBridge() {
        val messenger = FixtureMessenger()
        lateinit var activity: FixtureActivity
        lateinit var session: DocumentAccessSession
        val requests = mutableMapOf<CompletableFuture<Any?>, String>()
        runOnMainSync {
            activity = FixtureActivity(targetContext)
            session = DocumentAccessSession(activity, messenger)
        }
        fun request(method: String, args: Any? = null): CompletableFuture<Any?> {
            val future = CompletableFuture<Any?>()
            requests[future] = method
            runOnMainSync { messenger.request(method, args, future) }
            return future
        }
        fun await(future: CompletableFuture<Any?>): Any? = try {
            future.get(10, TimeUnit.SECONDS)
        } catch (error: java.util.concurrent.TimeoutException) {
            throw IllegalStateException("Timed out at ${requests[future]}", error)
        }
        fun pick(uri: Uri?, mode: String): Any? {
            val picked = request("pick", mapOf("mode" to mode, "mimeType" to "application/octet-stream", "suggestedName" to "fixture.bin"))
            check(activity.launched!!.action == if (mode == "read") Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT)
            check(activity.launched!!.categories.contains(Intent.CATEGORY_OPENABLE))
            val data = uri?.let { Intent().setData(it).addFlags(if (mode == "read") Intent.FLAG_GRANT_READ_URI_PERMISSION else Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            runOnMainSync { check(session.onActivityResult(activity.requestCode, if (uri == null) Activity.RESULT_CANCELED else Activity.RESULT_OK, data)) }
            return await(picked)
        }
        fun expectError(code: String, future: CompletableFuture<Any?>) {
            try {
                await(future)
                error("Expected $code")
            } catch (error: java.util.concurrent.ExecutionException) {
                check((error.cause as FlutterException).code == code)
            }
        }

        val input = Uri.parse("content://com.example.ssh_mobile.test.documents/input")
        val output = Uri.parse("content://com.example.ssh_mobile.test.documents/output")
        val publicBytes = ByteArray(24 * 1024 + 7) { (it % 251).toByte() }
        val foreign = File(targetContext.cacheDir, "saf-public-foreign.bin")
        try {
            targetContext.contentResolver.openOutputStream(output, "wt")!!.use { it.write(publicBytes) }
            check(pick(null, "read") == null)
            val selected = pick(input, "read") as Map<*, *>
            check(selected["displayName"] == "fixture.bin")
            check((selected["size"] as Number).toInt() == publicBytes.size)
            check(pick(null, "read") == null)
            val cached = await(request("copyToCache", mapOf("uri" to input.toString(), "maxBytes" to 40000))) as Map<*, *>
            val cachedFile = File(cached["path"] as String)
            check(cachedFile.readBytes().contentEquals(publicBytes))
            expectError("DOCUMENT_TOO_LARGE", request("copyToCache", mapOf("uri" to input.toString(), "maxBytes" to 4)))
            check(await(request("release", mapOf("uri" to input.toString(), "mode" to "read"))) == true)
            expectError("DOCUMENT_DENIED", request("copyToCache", mapOf("uri" to input.toString(), "maxBytes" to 40000)))

            pick(output, "write")
            val reserved = await(request("reserveStaging")) as Map<*, *>
            val staging = File(reserved["path"] as String)
            staging.writeBytes(byteArrayOf(5, 7, 9))
            await(request("copyFromCache", mapOf("uri" to output.toString(), "path" to staging.path)))
            val actual = targetContext.contentResolver.openInputStream(output)!!.use { it.readBytes() }
            check(actual.contentEquals(byteArrayOf(5, 7, 9))) // Also proves truncation of the long fixture.
            foreign.writeText("public fixture")
            expectError("DOCUMENT_MISSING", request("copyFromCache", mapOf("uri" to output.toString(), "path" to foreign.path)))
            expectError("DOCUMENT_DENIED", request("copyToCache", mapOf("uri" to output.toString(), "maxBytes" to 100)))

            val slowInput = Uri.parse("content://com.example.ssh_mobile.test.documents/slow-input")
            pick(slowInput, "read")
            val cancelledRead = request("copyToCache", mapOf("uri" to slowInput.toString(), "maxBytes" to 40000, "operationId" to "fixture-read"))
            await(request("cancelCopy", mapOf("operationId" to "fixture-read")))
            expectError("DOCUMENT_CANCELLED", cancelledRead)
            await(request("release", mapOf("uri" to slowInput.toString(), "mode" to "read")))

            val slowOutput = Uri.parse("content://com.example.ssh_mobile.test.documents/slow-output")
            pick(slowOutput, "write")
            val large = await(request("reserveStaging")) as Map<*, *>
            val largeFile = File(large["path"] as String).apply { writeBytes(ByteArray(1024 * 1024) { 4 }) }
            val cancelledWrite = request("copyFromCache", mapOf("uri" to slowOutput.toString(), "path" to largeFile.path, "operationId" to "fixture-write"))
            await(request("cancelCopy", mapOf("operationId" to "fixture-write")))
            expectError("DOCUMENT_CANCELLED", cancelledWrite)
            await(request("release", mapOf("uri" to slowOutput.toString(), "mode" to "write")))
            check(cachedFile.parentFile!!.listFiles()!!.size == 3) // Failed and cancelled imports left no partial file.

            try {
                pick(Uri.parse("content://com.example.ssh_mobile.test.documents/query-denied"), "read")
                error("Expected denied metadata")
            } catch (error: java.util.concurrent.ExecutionException) {
                check((error.cause as FlutterException).code == "DOCUMENT_DENIED")
            }

            val invalid = request("pick", mapOf("mode" to "read"))
            runOnMainSync { session.onActivityResult(activity.requestCode, Activity.RESULT_OK, Intent().setData(Uri.parse("file:///public-fixture"))) }
            expectError("DOCUMENT_DENIED", invalid)
            pick(slowInput, "read")
            val stoppingCopy = request("copyToCache", mapOf("uri" to slowInput.toString(), "maxBytes" to 40000, "operationId" to "fixture-shutdown"))
            val pending = request("pick", mapOf("mode" to "read"))
            runOnMainSync { session.dispose() }
            check(await(pending) == null)
            expectError("DOCUMENT_IO", stoppingCopy)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (cachedFile.parentFile!!.exists() && System.nanoTime() < deadline) Thread.sleep(10)
            check(!cachedFile.parentFile!!.exists())
            check(foreign.readText() == "public fixture")
        } finally {
            runOnMainSync { session.dispose() }
            foreign.delete()
        }
    }

    private class FixtureActivity(context: Context) : Activity() {
        init { attachBaseContext(context) }
        var launched: Intent? = null
        var requestCode = 0
        override fun startActivityForResult(intent: Intent, requestCode: Int) {
            this.launched = intent
            this.requestCode = requestCode
        }
    }

    private class FixtureMessenger : BinaryMessenger {
        private var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) { this.handler = handler }
        fun request(method: String, args: Any?, future: CompletableFuture<Any?>) {
            val bytes = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args))
            bytes.flip()
            handler!!.onMessage(bytes) { response ->
                try {
                    val envelope = response ?: error("Missing reply")
                    envelope.flip()
                    future.complete(StandardMethodCodec.INSTANCE.decodeEnvelope(envelope))
                } catch (error: Throwable) {
                    future.completeExceptionally(error)
                }
            }
        }
    }
}
