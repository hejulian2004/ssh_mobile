package com.example.ssh_mobile

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import javax.crypto.Cipher

internal object CredentialErrors {
    const val CANCELLED = "CREDENTIAL_CANCELLED"
    const val UNAVAILABLE = "CREDENTIAL_UNAVAILABLE"
    const val INVALIDATED = "CREDENTIAL_INVALIDATED"
    const val MISSING = "CREDENTIAL_MISSING"
    const val BUSY = "CREDENTIAL_BUSY"
    const val INVALID_ARGUMENT = "CREDENTIAL_INVALID_ARGUMENT"
    const val CRYPTO = "CREDENTIAL_CRYPTO"
}

internal class CredentialProtectionException(val code: String) : Exception()

/** Connection and revision are immutable and length-prefixed, never concatenated ambiguously. */
internal class CredentialBinding(val connectionId: String, val revision: String) {
    init {
        require(connectionId.isNotBlank() && connectionId.length <= 256)
        require(revision.isNotBlank() && revision.length <= 128)
    }

    private val associatedData = ByteArrayOutputStream().use { bytes ->
        DataOutputStream(bytes).use {
            it.write("ssh-mobile-credential-v1".toByteArray(Charsets.UTF_8))
            it.writeByte(0)
            for (value in listOf(connectionId, revision)) {
                val encoded = value.toByteArray(Charsets.UTF_8)
                it.writeInt(encoded.size)
                it.write(encoded)
            }
        }
        bytes.toByteArray()
    }

    val alias = "ssh_mobile.credential.v1." + MessageDigest.getInstance("SHA-256")
        .digest(associatedData).joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }

    fun aad(): ByteArray = associatedData.copyOf()
}

internal enum class CredentialMode { Seal, Open }

internal object CredentialRequestPolicy {
    const val MAX_PLAINTEXT_BYTES = 512 * 1024
    const val IV_BYTES = 12
    const val TAG_BYTES = 16

    fun validate(operationId: String, mode: CredentialMode, input: ByteArray, iv: ByteArray?) {
        require(operationId.isNotBlank() && operationId.length <= 128)
        when (mode) {
            CredentialMode.Seal -> require(input.size <= MAX_PLAINTEXT_BYTES && iv == null)
            CredentialMode.Open -> require(input.size in TAG_BYTES..MAX_PLAINTEXT_BYTES + TAG_BYTES && iv?.size == IV_BYTES)
        }
    }
}

internal sealed class CredentialOutcome {
    class Success(val bytes: ByteArray, val iv: ByteArray?) : CredentialOutcome()
    class Failure(val code: String) : CredentialOutcome()
}

/** One request owns one Cipher, one private input copy and exactly one terminal reply. */
internal class CredentialAttempt(
    val operationId: String,
    val binding: CredentialBinding,
    val mode: CredentialMode,
    input: ByteArray,
    private val reply: (CredentialOutcome) -> Unit,
) {
    private val input = input.copyOf()
    private var cipher: Cipher? = null
    private var terminal = false

    val isPending: Boolean @Synchronized get() = !terminal

    @Synchronized
    fun bind(value: Cipher): Boolean {
        if (terminal || cipher != null) return false
        cipher = value
        return true
    }

    @Synchronized
    fun succeed(authenticated: Cipher?) {
        if (terminal) return
        val prepared = cipher
        val outcome = if (prepared == null || prepared !== authenticated) {
            CredentialOutcome.Failure(CredentialErrors.CRYPTO)
        } else {
            try {
                prepared.updateAAD(binding.aad())
                val bytes = prepared.doFinal(input)
                CredentialOutcome.Success(bytes, if (mode == CredentialMode.Seal) prepared.iv.copyOf() else null)
            } catch (_: Exception) {
                CredentialOutcome.Failure(CredentialErrors.CRYPTO)
            }
        }
        finish(outcome)
    }

    @Synchronized
    fun fail(code: String) {
        if (!terminal) finish(CredentialOutcome.Failure(code))
    }

    private fun finish(outcome: CredentialOutcome) {
        terminal = true
        cipher = null
        input.fill(0)
        reply(outcome)
    }
}
