package com.example.ssh_mobile

import android.app.Activity
import android.app.Instrumentation
import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Test APK only. Negative device contract uses only fixed public fixture identifiers. */
class CredentialProtectionInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        try {
            exerciseNegativeContract()
            val secure = targetContext.getSystemService(KeyguardManager::class.java).isDeviceSecure
            val ready = targetContext.getSystemService(BiometricManager::class.java)
                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
            report.putString("stream", "Credential negative contract passed; deviceSecure=$secure; strongBiometricReady=$ready; authenticated round-trip requires enrolled fixture\n")
            finish(Activity.RESULT_OK, report)
        } catch (error: Throwable) {
            report.putString("stream", "Credential negative contract failed: ${error.javaClass.simpleName}\n")
            finish(Activity.RESULT_CANCELED, report)
        }
    }

    private fun exerciseNegativeContract() {
        val binding = CredentialBinding("public-instrumentation-connection", "public-instrumentation-revision")
        val keys = AndroidCredentialKeys()
        keys.removeAlias(binding.alias)
        try {
            keys.prepareOpen(binding, ByteArray(12))
            error("Missing key must not be replaced")
        } catch (error: CredentialProtectionException) {
            check(error.code == CredentialErrors.MISSING)
        }
        check(!KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(binding.alias))

        val messenger = FixtureMessenger()
        lateinit var session: CredentialProtectionSession
        runOnMainSync { session = CredentialProtectionSession(FixtureActivity(targetContext), messenger) }
        fun request(method: String, args: Any? = null): Any? {
            val future = CompletableFuture<Any?>()
            runOnMainSync { messenger.request(method, args, future) }
            return future.get(10, TimeUnit.SECONDS)
        }
        fun error(code: String, method: String, args: Any?) {
            try { request(method, args); kotlin.error("Expected $code") }
            catch (error: java.util.concurrent.ExecutionException) { check((error.cause as FlutterException).code == code) }
        }
        try {
            check(request("capability") == true)
            val arguments = mapOf("connectionId" to binding.connectionId, "revision" to binding.revision, "operationId" to "public-operation", "plaintext" to "public fixture".toByteArray())
            error(CredentialErrors.CANCELLED, "seal", arguments)
            check(request("cancel", mapOf("operationId" to "other")) == false)
            error(CredentialErrors.INVALID_ARGUMENT, "removeKey", mapOf("connectionId" to ""))
            check(request("removeKey", arguments) == true)
        } finally {
            runOnMainSync { session.dispose() }
            keys.removeAlias(binding.alias)
        }
    }

    private class FixtureActivity(context: Context) : Activity() { init { attachBaseContext(context) } }

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
                } catch (error: Throwable) { future.completeExceptionally(error) }
            }
        }
    }
}
