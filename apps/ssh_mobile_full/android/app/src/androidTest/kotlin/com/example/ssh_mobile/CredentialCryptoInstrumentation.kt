package com.example.ssh_mobile

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.os.Bundle
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/** Requires an enrolled emulator fixture; authenticate each announced stage with its test finger. */
class CredentialCryptoInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        try {
            exerciseAuthenticatedContract()
            report.putString("stream", "Credential CryptoObject round-trip, per-use key policy, tamper/missing/cancel/background contracts passed\n")
            finish(Activity.RESULT_OK, report)
        } catch (error: Throwable) {
            val site = error.stackTrace.firstOrNull { it.fileName == "CredentialCryptoInstrumentation.kt" }
            val code = (error.cause as? FlutterException)?.code
            report.putString("stream", "Credential CryptoObject contract failed: ${error.javaClass.simpleName}; code=$code; $site\n")
            finish(Activity.RESULT_CANCELED, report)
        }
    }

    private fun exerciseAuthenticatedContract() {
        check(targetContext.getSystemService(BiometricManager::class.java)
            .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS)
        val keys = AndroidCredentialKeys()
        val binding = CredentialBinding("public-crypto-fixture", "public-crypto-revision")
        val unauthenticated = CredentialBinding("public-crypto-fixture", "public-unauthenticated-revision")
        keys.removeAlias(binding.alias)
        keys.removeAlias(unauthenticated.alias)
        val activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val messenger = FixtureMessenger()
        lateinit var session: CredentialProtectionSession
        runOnMainSync { session = CredentialProtectionSession(activity, messenger, initiallyForeground = true) }
        fun request(method: String, args: Any? = null): CompletableFuture<Any?> {
            val future = CompletableFuture<Any?>()
            runOnMainSync { messenger.request(method, args, future) }
            return future
        }
        fun await(future: CompletableFuture<Any?>): Any? = future.get(45, TimeUnit.SECONDS)
        fun expectError(code: String, future: CompletableFuture<Any?>) {
            try { await(future); error("Expected $code") }
            catch (error: java.util.concurrent.ExecutionException) { check((error.cause as FlutterException).code == code) }
        }
        fun authenticate(stage: String, method: String, args: Any?): Any? {
            val future = request(method, args)
            check(!future.isDone)
            sendStatus(0, Bundle().apply { putString("stage", stage) })
            return await(future)
        }
        try {
            val unauthedCipher = keys.prepareSeal(unauthenticated) { }
            val key = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(unauthenticated.alias, null) as SecretKey
            check(key.encoded == null)
            val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
            sendStatus(0, Bundle().apply {
                putString("stage", "key_policy")
                putBoolean("requiresAuthentication", info.isUserAuthenticationRequired)
                putInt("validitySeconds", info.userAuthenticationValidityDurationSeconds)
                putInt("authenticationType", info.userAuthenticationType)
                putBoolean("invalidatesOnEnrollment", info.isInvalidatedByBiometricEnrollment)
            })
            // Legacy KeyInfo reports -1; current KeyMint reports the configured zero timeout.
            check(info.isUserAuthenticationRequired && info.userAuthenticationValidityDurationSeconds in -1..0)
            check(info.userAuthenticationType == KeyProperties.AUTH_BIOMETRIC_STRONG)
            check(info.isInvalidatedByBiometricEnrollment)
            try {
                unauthedCipher.doFinal("public fixture".toByteArray())
                error("Key must not work without CryptoObject authentication")
            } catch (_: GeneralSecurityException) { }

            val base = mapOf("connectionId" to binding.connectionId, "revision" to binding.revision)
            val sealed = authenticate("await_seal_authentication", "seal", base + mapOf("operationId" to "fixture-seal", "plaintext" to "public fixture".toByteArray())) as Map<*, *>
            val iv = sealed["iv"] as ByteArray
            val ciphertext = sealed["ciphertext"] as ByteArray
            check(iv.size == 12 && ciphertext.size == "public fixture".length + 16)
            val openArgs = base + mapOf("iv" to iv, "ciphertext" to ciphertext)
            val plaintext = authenticate("await_open_authentication", "open", openArgs + mapOf("operationId" to "fixture-open")) as ByteArray
            check(String(plaintext) == "public fixture")
            plaintext.fill(0)

            val cancelled = request("open", openArgs + mapOf("operationId" to "fixture-cancel"))
            check(await(request("cancel", mapOf("operationId" to "fixture-cancel"))) == true)
            expectError(CredentialErrors.CANCELLED, cancelled)
            val background = request("open", openArgs + mapOf("operationId" to "fixture-background"))
            runOnMainSync { session.setForeground(false) }
            expectError(CredentialErrors.CANCELLED, background)
            runOnMainSync { session.setForeground(true) }
            expectError(CredentialErrors.MISSING, request("open", openArgs + mapOf("operationId" to "fixture-missing", "revision" to "missing-revision")))

            val tampered = ciphertext.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
            val tamperFuture = request("open", openArgs + mapOf("operationId" to "fixture-tamper", "ciphertext" to tampered))
            sendStatus(0, Bundle().apply { putString("stage", "await_tamper_authentication") })
            expectError(CredentialErrors.CRYPTO, tamperFuture)
            check(await(request("removeKey", base)) == true)
            expectError(CredentialErrors.MISSING, request("open", openArgs + mapOf("operationId" to "fixture-removed")))
        } finally {
            runOnMainSync { session.dispose(); activity.finish() }
            keys.removeAlias(binding.alias)
            keys.removeAlias(unauthenticated.alias)
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
                } catch (error: Throwable) { future.completeExceptionally(error) }
            }
        }
    }
}
