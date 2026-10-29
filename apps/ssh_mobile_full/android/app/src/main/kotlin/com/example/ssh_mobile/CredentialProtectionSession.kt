package com.example.ssh_mobile

import android.app.Activity
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Android-only binding. The Activity owns prompts; AndroidKeyStore owns non-exportable keys. */
internal class CredentialProtectionSession(
    private val activity: Activity,
    messenger: BinaryMessenger,
    initiallyForeground: Boolean = false,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val createdKeys = ConcurrentHashMap<CredentialAttempt, String>()
    private val keys = AndroidCredentialKeys()
    private var active: CredentialAttempt? = null
    private var authentication: CancellationSignal? = null
    @Volatile private var foreground = initiallyForeground
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (disposed) {
                result.error(CredentialErrors.CANCELLED, "Credential protection was cancelled.", null)
                return@setMethodCallHandler
            }
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "capability" -> executor.execute {
                    val supported = Build.VERSION.SDK_INT >= 30 && runCatching { keys.checkAvailable() }.isSuccess
                    main.post { reply(result) { result.success(supported) } }
                }
                "seal" -> begin(args, CredentialMode.Seal, result)
                "open" -> begin(args, CredentialMode.Open, result)
                "cancel" -> {
                    val id = args?.get("operationId") as? String
                    val matched = active?.operationId == id && active?.isPending == true
                    if (matched) cancelActive()
                    result.success(matched)
                }
                "removeKey" -> removeKey(args, result)
                else -> result.notImplemented()
            }
        }
    }

    fun setForeground(value: Boolean) {
        foreground = value
        if (!value) cancelActive()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        foreground = false
        cancelActive()
        channel.setMethodCallHandler(null)
        // Also compensates a key created by preparation after cancellation.
        executor.execute {
            createdKeys.keys.forEach(::discardCreatedKey)
        }
        executor.shutdown()
    }

    private fun begin(args: Map<*, *>?, mode: CredentialMode, result: MethodChannel.Result) {
        val input = args?.get(if (mode == CredentialMode.Seal) "plaintext" else "ciphertext") as? ByteArray
        try {
            if (disposed || !foreground || activity.isFinishing || activity.isDestroyed) {
                throw CredentialProtectionException(CredentialErrors.CANCELLED)
            }
            if (active != null) throw CredentialProtectionException(CredentialErrors.BUSY)
            if (!ready()) throw CredentialProtectionException(CredentialErrors.UNAVAILABLE)
            val target = binding(args)
            val id = args?.get("operationId") as? String ?: throw IllegalArgumentException()
            val bytes = input ?: throw IllegalArgumentException()
            val iv = (args["iv"] as? ByteArray)?.copyOf()
            CredentialRequestPolicy.validate(id, mode, bytes, iv)
            lateinit var attempt: CredentialAttempt
            attempt = CredentialAttempt(id, target, mode, bytes) { outcome -> complete(attempt, outcome, result) }
            active = attempt
            executor.execute {
                // Retain failed removals and retry them on later use of this owner.
                createdKeys.keys.filter { it !== attempt && !it.isPending }.forEach(::discardCreatedKey)
                if (!attempt.isPending) return@execute
                try {
                    val cipher = when (mode) {
                        CredentialMode.Seal -> keys.prepareSeal(target) { createdKeys[attempt] = target.alias }
                        CredentialMode.Open -> keys.prepareOpen(target, iv!!)
                    }
                    if (!attempt.bind(cipher)) return@execute
                    main.post { authenticate(attempt, cipher) }
                } catch (error: Exception) {
                    attempt.fail(errorCode(error))
                }
            }
        } catch (error: Exception) {
            result.error(errorCode(error), "Credential protection could not continue.", null)
        } finally {
            if (mode == CredentialMode.Seal) input?.fill(0)
        }
    }

    private fun authenticate(attempt: CredentialAttempt, cipher: Cipher) {
        if (!attempt.isPending) return
        if (disposed || !foreground || activity.isFinishing || activity.isDestroyed) {
            attempt.fail(CredentialErrors.CANCELLED)
            return
        }
        if (!ready()) {
            attempt.fail(CredentialErrors.UNAVAILABLE)
            return
        }
        try {
            val cancellation = CancellationSignal()
            authentication = cancellation
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle(activity.getString(R.string.credential_protection_title))
                .setSubtitle(activity.getString(R.string.credential_protection_subtitle))
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButton(activity.getString(R.string.credential_protection_cancel), activity.mainExecutor) { _, _ ->
                    attempt.fail(CredentialErrors.CANCELLED)
                }
                .build()
            prompt.authenticate(BiometricPrompt.CryptoObject(cipher), cancellation, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (!attempt.isPending || disposed || executor.isShutdown) return
                        val authenticated = result.cryptoObject?.cipher
                        executor.execute { attempt.succeed(authenticated) }
                    }
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        val cancelled = code == BiometricPrompt.BIOMETRIC_ERROR_CANCELED ||
                            code == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED
                        attempt.fail(if (cancelled) CredentialErrors.CANCELLED else CredentialErrors.UNAVAILABLE)
                    }
                })
        } catch (error: Exception) {
            attempt.fail(errorCode(error))
        }
    }

    private fun complete(attempt: CredentialAttempt, outcome: CredentialOutcome, result: MethodChannel.Result) {
        main.post {
            if (active === attempt) {
                active = null
                authentication = null
            }
            val deliver = !disposed && foreground && !activity.isFinishing && !activity.isDestroyed
            if (outcome is CredentialOutcome.Failure || !deliver) {
                if (!executor.isShutdown) executor.execute { discardCreatedKey(attempt) }
            } else {
                createdKeys.remove(attempt) // The caller now owns the envelope/key revision.
            }
            reply(result) {
                when {
                    !deliver -> result.error(CredentialErrors.CANCELLED, "Credential protection was cancelled.", null)
                    outcome is CredentialOutcome.Failure -> result.error(outcome.code, "Credential protection could not continue.", null)
                    outcome is CredentialOutcome.Success -> result.success(
                        if (attempt.mode == CredentialMode.Seal) mapOf("iv" to outcome.iv, "ciphertext" to outcome.bytes) else outcome.bytes,
                    )
                }
            }
            if (outcome is CredentialOutcome.Success) outcome.bytes.fill(0)
        }
    }

    private fun cancelActive() {
        active?.fail(CredentialErrors.CANCELLED)
        runCatching { authentication?.cancel() }
        authentication = null
    }

    private fun removeKey(args: Map<*, *>?, result: MethodChannel.Result) {
        val target = try { binding(args) } catch (_: Exception) {
            result.error(CredentialErrors.INVALID_ARGUMENT, "Credential binding is invalid.", null)
            return
        }
        if (active?.binding?.alias == target.alias) cancelActive()
        executor.execute {
            val error = runCatching { keys.removeAlias(target.alias) }.exceptionOrNull()
            if (error == null) {
                createdKeys.entries.removeIf { it.value == target.alias }
            }
            main.post {
                reply(result) {
                    if (error == null) result.success(true)
                    else result.error(errorCode(error), "Credential key could not be removed.", null)
                }
            }
        }
    }

    private fun discardCreatedKey(attempt: CredentialAttempt) {
        val alias = createdKeys[attempt] ?: return
        runCatching { keys.removeAlias(alias) }.onSuccess { createdKeys.remove(attempt, alias) }
    }

    private fun binding(args: Map<*, *>?) = CredentialBinding(
        args?.get("connectionId") as? String ?: throw IllegalArgumentException(),
        args["revision"] as? String ?: throw IllegalArgumentException(),
    )

    private fun ready(): Boolean = Build.VERSION.SDK_INT >= 30 &&
        activity.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true &&
        activity.getSystemService(BiometricManager::class.java)
            ?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    private fun errorCode(error: Throwable): String = when (error) {
        is CredentialProtectionException -> error.code
        is KeyPermanentlyInvalidatedException -> CredentialErrors.INVALIDATED
        is IllegalArgumentException -> CredentialErrors.INVALID_ARGUMENT
        else -> CredentialErrors.CRYPTO
    }

    private fun reply(result: MethodChannel.Result, block: () -> Unit) {
        try { block() } catch (_: RuntimeException) { /* Engine has detached; never log the payload. */ }
    }

    companion object { const val CHANNEL = "ssh_mobile/credential_protection" }
}

/** Platform adapter: open never generates or replaces a missing/invalidated key. */
internal class AndroidCredentialKeys {
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun checkAvailable() { store() }

    fun prepareSeal(binding: CredentialBinding, onCreated: () -> Unit): Cipher {
        if (store().containsAlias(binding.alias)) throw CredentialProtectionException(CredentialErrors.CRYPTO)
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(binding.alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .build())
        val key = generator.generateKey()
        onCreated()
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, key)
        }
    }

    fun prepareOpen(binding: CredentialBinding, iv: ByteArray): Cipher {
        val key = store().getKey(binding.alias, null) as? SecretKey
            ?: throw CredentialProtectionException(CredentialErrors.MISSING)
        return Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        }
    }

    fun removeAlias(alias: String) { store().deleteEntry(alias) }
}
