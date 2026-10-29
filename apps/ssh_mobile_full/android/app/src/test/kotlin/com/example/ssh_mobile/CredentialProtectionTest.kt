package com.example.ssh_mobile

import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.*
import org.junit.Test

class CredentialProtectionTest {
    @Test
    fun authenticatedCipherIdentityIsRequiredAndCompletionIsExactlyOnce() {
        val binding = CredentialBinding("public-connection", "public-revision")
        val replies = mutableListOf<CredentialOutcome>()
        val operation = CredentialAttempt("operation", binding, CredentialMode.Seal, "public fixture".toByteArray(), replies::add)
        val prepared = cipher(Cipher.ENCRYPT_MODE, binding)
        assertTrue(operation.bind(prepared))
        assertFalse(operation.bind(cipher(Cipher.ENCRYPT_MODE, binding)))
        operation.succeed(cipher(Cipher.ENCRYPT_MODE, binding))
        operation.succeed(prepared)
        operation.fail(CredentialErrors.CANCELLED)
        assertEquals(CredentialErrors.CRYPTO, (replies.single() as CredentialOutcome.Failure).code)
        assertFalse(operation.isPending)
        assertFalse(operation.bind(prepared))
    }

    @Test
    fun authenticatedRoundTripOwnsInputAndEachOperationNeedsItsOwnSuccess() {
        val binding = CredentialBinding("public-connection", "public-revision")
        val replies = mutableListOf<CredentialOutcome>()
        val input = "public fixture".toByteArray()
        val operation = CredentialAttempt("seal", binding, CredentialMode.Seal, input, replies::add)
        input.fill(0)
        val encrypt = cipher(Cipher.ENCRYPT_MODE, binding, bindAad = false)
        assertTrue(operation.isPending)
        assertTrue(operation.bind(encrypt))
        operation.succeed(encrypt)
        val sealed = replies.single() as CredentialOutcome.Success
        val opens = mutableListOf<CredentialOutcome>()
        val open = CredentialAttempt("open", binding, CredentialMode.Open, sealed.bytes, opens::add)
        val decrypt = cipher(Cipher.DECRYPT_MODE, binding, sealed.iv, bindAad = false)
        assertTrue(open.bind(decrypt))
        assertTrue(opens.isEmpty())
        open.succeed(decrypt)
        assertEquals("public fixture", String((opens.single() as CredentialOutcome.Success).bytes))
        assertNull((opens.single() as CredentialOutcome.Success).iv)
        assertEquals("public fixture", String(cipher(Cipher.DECRYPT_MODE, binding, sealed.iv).doFinal(sealed.bytes)))
    }

    @Test
    fun cancellationBeforeAndAfterPreparationRejectsLateAuthentication() {
        val binding = CredentialBinding("public-connection", "public-revision")
        for (prepared in listOf(false, true)) {
            val replies = mutableListOf<CredentialOutcome>()
            val operation = CredentialAttempt("cancel", binding, CredentialMode.Seal, byteArrayOf(1), replies::add)
            val encrypt = cipher(Cipher.ENCRYPT_MODE, binding)
            if (prepared) assertTrue(operation.bind(encrypt))
            operation.fail(CredentialErrors.CANCELLED)
            operation.fail(CredentialErrors.UNAVAILABLE)
            operation.succeed(encrypt)
            assertFalse(operation.bind(encrypt))
            assertEquals(CredentialErrors.CANCELLED, (replies.single() as CredentialOutcome.Failure).code)
        }
    }

    @Test
    fun missingCipherAndTamperedCiphertextCannotProducePlaintext() {
        val binding = CredentialBinding("public-connection", "public-revision")
        val replies = mutableListOf<CredentialOutcome>()
        CredentialAttempt("unprepared", binding, CredentialMode.Open, byteArrayOf(1), replies::add).succeed(null)
        assertEquals(CredentialErrors.CRYPTO, (replies.single() as CredentialOutcome.Failure).code)
        val encrypt = cipher(Cipher.ENCRYPT_MODE, binding)
        val bytes = encrypt.doFinal(byteArrayOf(1, 2, 3)).also { it[0] = (it[0].toInt() xor 1).toByte() }
        val tampered = CredentialAttempt("tampered", binding, CredentialMode.Open, bytes, replies::add)
        val decrypt = cipher(Cipher.DECRYPT_MODE, binding, encrypt.iv)
        tampered.bind(decrypt)
        tampered.succeed(decrypt)
        assertTrue(replies.all { it is CredentialOutcome.Failure })
    }

    @Test
    fun malformedBindingsAndUnboundedInputsAreRejected() {
        for ((id, revision) in listOf("" to "r", "c" to "", "c".repeat(257) to "r", "c" to "r".repeat(129))) {
            try { CredentialBinding(id, revision); fail("invalid binding") } catch (_: IllegalArgumentException) { }
        }
        val validIv = ByteArray(12)
        CredentialRequestPolicy.validate("valid", CredentialMode.Seal, byteArrayOf(), null)
        CredentialRequestPolicy.validate("valid", CredentialMode.Open, ByteArray(16), validIv)
        for (id in listOf("", "x".repeat(129))) {
            try { CredentialRequestPolicy.validate(id, CredentialMode.Seal, byteArrayOf(), null); fail("invalid operation") } catch (_: IllegalArgumentException) { }
        }
        for ((mode, bytes, iv) in listOf(
            Triple(CredentialMode.Seal, ByteArray(512 * 1024 + 1), null),
            Triple(CredentialMode.Seal, byteArrayOf(), validIv),
            Triple(CredentialMode.Open, ByteArray(15), validIv),
            Triple(CredentialMode.Open, ByteArray(512 * 1024 + 17), validIv),
            Triple(CredentialMode.Open, ByteArray(16), ByteArray(8)),
        )) {
            try { CredentialRequestPolicy.validate("valid", mode, bytes, iv); fail("invalid envelope") } catch (_: IllegalArgumentException) { }
        }
        val binding = CredentialBinding("c", "r")
        val exposed = binding.aad().also { it.fill(0) }
        assertFalse(exposed.contentEquals(binding.aad()))
        assertEquals(CredentialErrors.MISSING, CredentialProtectionException(CredentialErrors.MISSING).code)
    }
    @Test
    fun connectionAndRevisionUseAnUnambiguousDomainBoundAlias() {
        val first = CredentialBinding("public-connection", "public-revision")
        val same = CredentialBinding("public-connection", "public-revision")
        val other = CredentialBinding("public-connection", "next-revision")
        assertTrue(first.alias.startsWith("ssh_mobile.credential.v1."))
        assertEquals(first.alias, same.alias)
        assertNotEquals(first.alias, other.alias)
        assertFalse(CredentialBinding("a/b", "c").aad().contentEquals(CredentialBinding("a", "b/c").aad()))
    }

    @Test
    fun changingConnectionOrRevisionCannotOpenAnAuthenticatedEnvelope() {
        val original = CredentialBinding("public-connection", "public-revision")
        val encrypted = cipher(Cipher.ENCRYPT_MODE, original)
        val bytes = encrypted.doFinal("public fixture".toByteArray())
        val same = cipher(Cipher.DECRYPT_MODE, original, encrypted.iv).doFinal(bytes)
        assertEquals("public fixture", String(same))
        for (other in listOf(CredentialBinding("other-connection", original.revision), CredentialBinding(original.connectionId, "other-revision"))) {
            try {
                cipher(Cipher.DECRYPT_MODE, other, encrypted.iv).doFinal(bytes)
                fail("Rebound envelope must be rejected")
            } catch (_: AEADBadTagException) { }
        }
    }

    private fun cipher(mode: Int, binding: CredentialBinding, iv: ByteArray? = null, bindAad: Boolean = true): Cipher {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val key = SecretKeySpec(ByteArray(32) { 7 }, "AES")
        if (iv == null) cipher.init(mode, key) else cipher.init(mode, key, GCMParameterSpec(128, iv))
        if (bindAad) cipher.updateAAD(binding.aad())
        return cipher
    }
}
