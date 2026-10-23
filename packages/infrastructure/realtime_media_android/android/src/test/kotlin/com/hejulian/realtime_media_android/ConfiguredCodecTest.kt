package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class ConfiguredCodecTest {
    private data class Codec(val name: String)

    @Test
    fun automaticSelectionPrefersHardwareAndFallsBackAfterConfirmedRelease() {
        val attempts = mutableListOf<String>()
        val candidates = listOf("cpu", "hardware")
            .filter { AndroidCodecFactory.isCodecAllowed(it == "hardware", it == "cpu") }
            .sortedBy { AndroidCodecFactory.codecPriority(it == "hardware") }
        val selected = acquireConfiguredCodec<String, Codec>(candidates,
            create = { Codec(it).also { codec -> attempts += "create:${codec.name}" } },
            configure = { if (it.name == "hardware") throw IllegalArgumentException("unsupported") },
            release = { attempts += "release:${it.name}" },
        )
        assertEquals("cpu", selected?.name)
        assertEquals(listOf("create:hardware", "release:hardware", "create:cpu"), attempts)
    }

    @Test
    fun automaticSelectionKeepsWorkingHardwareWithoutAllocatingSoftware() {
        val attempts = mutableListOf<String>()
        val candidates = listOf("cpu", "hardware")
            .sortedBy { AndroidCodecFactory.codecPriority(it == "hardware") }
        val selected = acquireConfiguredCodec<String, Codec>(candidates,
            create = { Codec(it).also { codec -> attempts += codec.name } },
            configure = {},
            release = { throw AssertionError("Selected codec remains owned") },
        )
        assertEquals("hardware", selected?.name)
        assertEquals(listOf("hardware"), attempts)
    }

    @Test
    fun releasesRejectedCodecBeforeTryingAnotherCandidate() {
        val calls = mutableListOf<String>()
        val selected = acquireConfiguredCodec<String, Codec>(listOf("unsupported", "supported"),
            create = { Codec(it).also { codec -> calls += "create:${codec.name}" } },
            configure = {
                calls += "configure:${it.name}"
                if (it.name == "unsupported") throw IllegalArgumentException("format")
            },
            release = { calls += "release:${it.name}" },
        )
        assertEquals("supported", selected?.name)
        assertEquals(listOf("create:unsupported", "configure:unsupported",
            "release:unsupported", "create:supported", "configure:supported"), calls)
    }

    @Test
    fun missingCodecDoesNotReleaseAnUnacquiredResource() {
        val released = mutableListOf<Codec>()
        val selected = acquireConfiguredCodec<String, Codec>(listOf("missing"),
            create = { throw IllegalStateException("unavailable") },
            configure = { _: Codec -> throw AssertionError("No codec") },
            release = { released += it },
        )
        assertNull(selected)
        assertEquals(emptyList<Codec>(), released)
    }

    @Test
    fun exhaustedCandidatesReleaseEachAttemptAndRemainUnavailable() {
        val released = mutableListOf<String>()
        assertNull(acquireConfiguredCodec<String, Codec>(listOf("a", "b"),
            create = { Codec(it) },
            configure = { throw IllegalStateException("format") },
            release = { released += it.name },
        ))
        assertEquals(listOf("a", "b"), released)
    }

    @Test
    fun cleanupFailureDoesNotAllocateAReplacementCodec() {
        val created = mutableListOf<String>()
        assertNull(acquireConfiguredCodec<String, Codec>(listOf("a", "b"),
            create = { created += it; Codec(it) },
            configure = { throw IllegalStateException("format") },
            release = { throw IllegalStateException("release") },
        ))
        assertEquals(listOf("a"), created)
    }

    @Test
    fun retryCannotChangeTheExplicitCodecMode() {
        val attempted = mutableListOf<String>()
        AndroidCodecFactory.withCodecMode(AndroidCodecMode.CPU) {
            val candidates = listOf("hardware", "cpu-rejected", "cpu-supported")
                .filter { AndroidCodecFactory.isCodecAllowed(it == "hardware", it != "hardware") }
            val codec = acquireConfiguredCodec<String, Codec>(candidates,
                create = { attempted += it; Codec(it) },
                configure = { if (it.name == "cpu-rejected") throw IllegalArgumentException("format") },
                release = {},
            )
            assertEquals("cpu-supported", codec?.name)
        }
        assertEquals(listOf("cpu-rejected", "cpu-supported"), attempted)
        assertEquals(true, AndroidCodecFactory.isCodecAllowed(true, false))
    }

    @Test
    fun successfulCodecIsTransferredWithoutReleaseOrFurtherAllocation() {
        val codec = Codec("selected")
        assertSame(codec, acquireConfiguredCodec<String, Codec>(listOf("a", "b"),
            create = { if (it == "b") throw AssertionError("No further allocation") else codec },
            configure = {},
            release = { throw AssertionError("Borrower owns selected codec") },
        ))
        assertNull(acquireConfiguredCodec<String, Codec>(emptyList<String>(),
            create = { throw AssertionError("No candidate") },
            configure = { _: Codec -> throw AssertionError("No codec") },
            release = { throw AssertionError("No codec") },
        ))
    }
}
