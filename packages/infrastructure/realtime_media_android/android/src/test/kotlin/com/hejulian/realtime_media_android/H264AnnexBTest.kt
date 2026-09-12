package com.hejulian.realtime_media_android

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class H264AnnexBTest {
    private val sps = nalu(7, 0x42, 0x00, 0x1f)
    private val pps = nalu(8, 0xce, 0x3c, 0x80)
    private val idr = nalu(5, 0x01, 0x02)
    private val delta = nalu(1, 0x09, 0x08)

    @Test
    fun parsesAnnexBParameterSetsAndIdr() {
        val info = H264AnnexB.analyze(accessUnit(sps, pps, idr))

        assertNotNull(info)
        assertEquals(listOf(7, 8, 5), info!!.nalUnits.map { it.type })
        assertTrue(info.containsIdr)
    }

    @Test
    fun currentIdrParameterSetsReplaceOldCacheWithoutDuplication() {
        val cache = H264ParameterSetCache()
        val oldSps = nalu(7, 0x42, 0x00, 0x0d)
        val oldPps = nalu(8, 0x01, 0x02)
        val newSps = nalu(7, 0x64, 0x00, 0x28)
        val newPps = nalu(8, 0x03, 0x04)
        cache.updateFromAccessUnit(requireInfo(accessUnit(oldSps, oldPps, idr)))

        val composed = cache.composeRecovery(
            requireInfo(accessUnit(newSps, newPps, idr)),
        )

        assertNotNull(composed)
        val info = H264AnnexB.analyze(composed!!)
        assertEquals(listOf(7, 8, 5), info!!.nalUnits.map { it.type })
        assertArrayEquals(newSps.copyOfRange(4, newSps.size), info.nalUnits[0].payload)
        assertArrayEquals(newPps.copyOfRange(4, newPps.size), info.nalUnits[1].payload)
        assertFalse(composed.containsBytes(oldSps.copyOfRange(4, oldSps.size)))
    }

    @Test
    fun recoveryOnlyFillsMissingParameterSetFromCache() {
        val cache = H264ParameterSetCache()
        cache.updateFromAccessUnit(requireInfo(accessUnit(sps, pps, idr)))
        val currentSps = nalu(7, 0x64, 0x00, 0x28)

        val composed = cache.composeRecovery(requireInfo(accessUnit(currentSps, idr)))

        assertNotNull(composed)
        assertEquals(
            listOf(7, 8, 5),
            H264AnnexB.analyze(composed!!)?.nalUnits?.map { it.type },
        )
        assertArrayEquals(
            currentSps.copyOfRange(4, currentSps.size),
            H264AnnexB.analyze(composed)!!.nalUnits[0].payload,
        )
        assertArrayEquals(
            pps.copyOfRange(4, pps.size),
            H264AnnexB.analyze(composed)!!.nalUnits[1].payload,
        )
    }

    @Test
    fun codecConfigAndAccessUnitCacheAreBoundedAndRejectMalformedData() {
        val cache = H264ParameterSetCache()
        assertTrue(
            cache.updateFromCodecConfig(sps, pps) != H264ParameterSetUpdate.REJECTED,
        )
        assertEquals(
            H264ParameterSetUpdate.NO_CHANGE,
            cache.updateFromCodecConfig(null, null),
        )
        assertNull(H264AnnexB.analyze(byteArrayOf(0, 0, 0, 1, 0)))
        assertNull(H264AnnexB.parseParameterSets(byteArrayOf(0x67)))

        val oversizedSps = ByteArray(H264ParameterSetCache.MAX_CSD_BYTES) { 0x67 }
        assertEquals(
            H264ParameterSetUpdate.REJECTED,
            cache.updateFromCodecConfig(oversizedSps, null),
        )
    }

    @Test
    fun recoveryGateDoesNotOpenWhenNativeDropsFirstRecoveryFrame() {
        val gate = H264EncoderRecoveryGate()
        assertTrue(gate.updateCodecConfig(sps, pps))

        assertNull(gate.prepare(delta, keyframe = false))
        val firstRecovery = gate.prepare(accessUnit(idr), keyframe = true)
        assertNotNull(firstRecovery)
        gate.onPushResult(keyframe = true, status = NativeMediaBridge.FRAME_DROPPED)
        assertTrue(gate.awaitingRecoveryKeyframe)
        assertNull(gate.prepare(delta, keyframe = false))

        val secondRecovery = gate.prepare(accessUnit(idr), keyframe = true)
        assertNotNull(secondRecovery)
        gate.onPushResult(keyframe = true, status = 0)
        assertFalse(gate.awaitingRecoveryKeyframe)
        assertNotNull(gate.prepare(delta, keyframe = false))
    }

    @Test
    fun decoderDropsDeltaUntilCsdAndRecoveryAreReadyAndReplaysCsdAfterReset() {
        val gate = H264DecoderRecoveryGate()
        val recovery = requireInfo(accessUnit(sps, pps, idr))
        val deltaInfo = requireInfo(accessUnit(delta))

        assertEquals(
            H264DecoderFrameDecision.DROP_AND_REQUEST,
            gate.inspect(deltaInfo, keyframe = false),
        )
        assertEquals(
            H264DecoderFrameDecision.WAIT_FOR_CSD,
            gate.inspect(recovery, keyframe = true),
        )
        assertTrue(gate.hasPendingConfig)
        gate.markConfigQueued()
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(recovery, keyframe = true),
        )
        gate.markFrameQueued(keyframe = true)
        assertFalse(gate.isAwaitingRecoveryKeyframe)
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(deltaInfo, keyframe = false),
        )

        gate.resetForFlush()
        assertEquals(
            H264DecoderFrameDecision.DROP_AND_REQUEST,
            gate.inspect(deltaInfo, keyframe = false),
        )
        assertEquals(
            H264DecoderFrameDecision.WAIT_FOR_CSD,
            gate.inspect(recovery, keyframe = true),
        )
        gate.markConfigQueued()
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(recovery, keyframe = true),
        )
    }

    @Test
    fun decoderRelocksAfterNonIdrParameterSetUpdate() {
        val gate = H264DecoderRecoveryGate()
        val initialRecovery = requireInfo(accessUnit(sps, pps, idr))
        val newSps = nalu(7, 0x64, 0x00, 0x28)
        val updatedDelta = requireInfo(accessUnit(newSps, delta))
        val newRecovery = requireInfo(accessUnit(newSps, pps, idr))

        assertEquals(
            H264DecoderFrameDecision.WAIT_FOR_CSD,
            gate.inspect(initialRecovery, keyframe = true),
        )
        gate.markConfigQueued()
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(initialRecovery, keyframe = true),
        )
        gate.markFrameQueued(keyframe = true)
        assertFalse(gate.isAwaitingRecoveryKeyframe)

        assertEquals(
            H264DecoderFrameDecision.DROP_AND_REQUEST,
            gate.inspect(updatedDelta, keyframe = false),
        )
        assertTrue(gate.isAwaitingRecoveryKeyframe)
        assertTrue(gate.hasPendingConfig)
        gate.markConfigQueued()
        assertEquals(
            H264DecoderFrameDecision.DROP_AND_REQUEST,
            gate.inspect(requireInfo(accessUnit(delta)), keyframe = false),
        )
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(newRecovery, keyframe = true),
        )
        gate.markFrameQueued(keyframe = true)
        assertFalse(gate.isAwaitingRecoveryKeyframe)
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(requireInfo(accessUnit(delta)), keyframe = false),
        )
    }

    @Test
    fun decoderRelocksAndReplaysWhenUpdatedCsdArrivesWithIdr() {
        val gate = H264DecoderRecoveryGate()
        val initialRecovery = requireInfo(accessUnit(sps, pps, idr))
        val newSps = nalu(7, 0x64, 0x00, 0x28)
        val updatedRecovery = requireInfo(accessUnit(newSps, pps, idr))

        assertEquals(
            H264DecoderFrameDecision.WAIT_FOR_CSD,
            gate.inspect(initialRecovery, keyframe = true),
        )
        gate.markConfigQueued()
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(initialRecovery, keyframe = true),
        )
        gate.markFrameQueued(keyframe = true)

        assertEquals(
            H264DecoderFrameDecision.WAIT_FOR_CSD,
            gate.inspect(updatedRecovery, keyframe = true),
        )
        assertTrue(gate.isAwaitingRecoveryKeyframe)
        gate.markConfigQueued()
        assertEquals(
            H264DecoderFrameDecision.QUEUE,
            gate.inspect(updatedRecovery, keyframe = true),
        )
        gate.markFrameQueued(keyframe = true)
        assertFalse(gate.isAwaitingRecoveryKeyframe)
    }

    private fun requireInfo(payload: ByteArray): H264AccessUnitInfo =
        H264AnnexB.analyze(payload) ?: error("test payload must be valid")

    private fun accessUnit(vararg nalUnits: ByteArray): ByteArray =
        nalUnits.fold(ByteArray(0)) { result, nal -> result + nal }

    private fun nalu(type: Int, vararg payload: Int): ByteArray =
        byteArrayOf(0, 0, 0, 1, type.toByte(), *payload.map { it.toByte() }.toByteArray())

    private fun ByteArray.containsBytes(needle: ByteArray): Boolean {
        if (needle.isEmpty() || needle.size > size) return false
        return (0..(size - needle.size)).any { offset ->
            copyOfRange(offset, offset + needle.size).contentEquals(needle)
        }
    }
}
