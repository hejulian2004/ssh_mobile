package com.hejulian.realtime_media_android

private const val MAX_ACCESS_UNIT_BYTES = 4 * 1024 * 1024

internal data class H264NalUnit(
    val type: Int,
    val payload: ByteArray,
)

internal data class H264AccessUnitInfo(
    val annexB: ByteArray,
    val nalUnits: List<H264NalUnit>,
) {
    val containsIdr: Boolean
        get() = nalUnits.any { it.type == 5 }

    val sps: ByteArray?
        get() = nalUnits.lastOrNull { it.type == 7 }?.payload

    val pps: ByteArray?
        get() = nalUnits.lastOrNull { it.type == 8 }?.payload
}

internal enum class H264ParameterSetUpdate {
    NO_CHANGE,
    UPDATED,
    REJECTED,
}

internal data class H264ParameterSetValues(
    val sps: ByteArray?,
    val pps: ByteArray?,
)

/** Bounded SPS/PPS state shared by one native encoder or decoder owner. */
internal class H264ParameterSetCache {
    companion object {
        const val MAX_CSD_BYTES = 64 * 1024
    }

    private var spsPayload: ByteArray? = null
    private var ppsPayload: ByteArray? = null
    private var versionValue = 0

    val isComplete: Boolean
        get() = spsPayload != null && ppsPayload != null

    val version: Int
        get() = versionValue

    fun clear() {
        spsPayload = null
        ppsPayload = null
        versionValue = 0
    }

    fun updateFromAccessUnit(info: H264AccessUnitInfo): H264ParameterSetUpdate =
        apply(info.sps, info.pps)

    fun updateFromCodecConfig(
        csd0: ByteArray?,
        csd1: ByteArray?,
    ): H264ParameterSetUpdate {
        if (csd0 == null && csd1 == null) return H264ParameterSetUpdate.NO_CHANGE
        val first = csd0?.let { H264AnnexB.parseParameterSets(it) }
        val second = csd1?.let { H264AnnexB.parseParameterSets(it) }
        if ((csd0 != null && first == null) || (csd1 != null && second == null)) {
            return H264ParameterSetUpdate.REJECTED
        }
        val sps = second?.sps ?: first?.sps
        val pps = second?.pps ?: first?.pps
        if (sps == null && pps == null) return H264ParameterSetUpdate.REJECTED
        return apply(sps, pps)
    }

    /** Returns SPS followed by PPS as one codec-config Annex-B buffer. */
    fun codecConfig(): ByteArray? {
        val sps = spsPayload ?: return null
        val pps = ppsPayload ?: return null
        return H264AnnexB.joinNalPayloads(listOf(sps, pps))
    }

    /**
     * Builds an IDR access unit with exactly one effective SPS and PPS.
     * Current parameter sets are preferred; the cache only fills missing
     * types, so old and new configurations are never duplicated together.
     */
    fun composeRecovery(info: H264AccessUnitInfo): ByteArray? {
        if (!info.containsIdr) return info.annexB
        val sps = info.sps ?: spsPayload ?: return null
        val pps = info.pps ?: ppsPayload ?: return null
        val nonParameterSets = info.nalUnits
            .filter { it.type != 7 && it.type != 8 }
            .map { it.payload }
        return H264AnnexB.joinNalPayloads(listOf(sps, pps) + nonParameterSets)
    }

    private fun apply(
        nextSps: ByteArray?,
        nextPps: ByteArray?,
    ): H264ParameterSetUpdate {
        if (nextSps == null && nextPps == null) return H264ParameterSetUpdate.NO_CHANGE
        val effectiveSps = nextSps ?: spsPayload
        val effectivePps = nextPps ?: ppsPayload
        val total = (effectiveSps?.size ?: 0) + (effectivePps?.size ?: 0) + 8
        if (total > MAX_CSD_BYTES) {
            return H264ParameterSetUpdate.REJECTED
        }
        val changed = (nextSps != null &&
            (spsPayload == null || !nextSps.contentEquals(spsPayload!!))) ||
            (nextPps != null &&
                (ppsPayload == null || !nextPps.contentEquals(ppsPayload!!)))
        if (!changed) return H264ParameterSetUpdate.NO_CHANGE
        if (nextSps != null) spsPayload = nextSps.copyOf()
        if (nextPps != null) ppsPayload = nextPps.copyOf()
        versionValue++
        return H264ParameterSetUpdate.UPDATED
    }
}

/** Keeps the encoder gated until native has accepted a complete recovery IDR. */
internal class H264EncoderRecoveryGate {
    private val cache = H264ParameterSetCache()

    var awaitingRecoveryKeyframe: Boolean = true
        private set

    fun updateCodecConfig(csd0: ByteArray?, csd1: ByteArray?): Boolean =
        cache.updateFromCodecConfig(csd0, csd1) != H264ParameterSetUpdate.REJECTED

    fun prepare(input: ByteArray, keyframe: Boolean): ByteArray? {
        val info = H264AnnexB.analyze(input) ?: return null
        return prepare(info, keyframe)
    }

    fun prepare(info: H264AccessUnitInfo, keyframe: Boolean): ByteArray? {
        if (cache.updateFromAccessUnit(info) == H264ParameterSetUpdate.REJECTED) {
            return null
        }
        if (awaitingRecoveryKeyframe) {
            if (!keyframe || !info.containsIdr) return null
            return cache.composeRecovery(info)
        }
        return if (keyframe) cache.composeRecovery(info) else info.annexB
    }

    fun onPushResult(keyframe: Boolean, status: Int) {
        if (awaitingRecoveryKeyframe && keyframe && status == 0) {
            awaitingRecoveryKeyframe = false
        }
    }
}

internal enum class H264DecoderFrameDecision {
    REJECTED,
    DROP_AND_REQUEST,
    WAIT_FOR_CSD,
    QUEUE,
}

/**
 * Keeps decoder input recovery explicit: a delta cannot occupy the pending
 * slot while the decoder is waiting for a complete CSD and recovery IDR.
 */
internal class H264DecoderRecoveryGate {
    internal val cache = H264ParameterSetCache()

    private var awaitingRecoveryKeyframe = true
    private var configPending = false

    val isAwaitingRecoveryKeyframe: Boolean
        get() = awaitingRecoveryKeyframe

    val hasPendingConfig: Boolean
        get() = configPending

    fun inspect(
        info: H264AccessUnitInfo,
        keyframe: Boolean,
    ): H264DecoderFrameDecision {
        return when (cache.updateFromAccessUnit(info)) {
            H264ParameterSetUpdate.REJECTED -> H264DecoderFrameDecision.REJECTED
            H264ParameterSetUpdate.UPDATED -> {
                awaitingRecoveryKeyframe = true
                configPending = cache.isComplete
                if (!keyframe) {
                    H264DecoderFrameDecision.DROP_AND_REQUEST
                } else if (!cache.isComplete) {
                    H264DecoderFrameDecision.DROP_AND_REQUEST
                } else {
                    H264DecoderFrameDecision.WAIT_FOR_CSD
                }
            }
            H264ParameterSetUpdate.NO_CHANGE -> when {
                !cache.isComplete -> H264DecoderFrameDecision.DROP_AND_REQUEST
                awaitingRecoveryKeyframe && !keyframe ->
                    H264DecoderFrameDecision.DROP_AND_REQUEST
                configPending -> H264DecoderFrameDecision.WAIT_FOR_CSD
                else -> H264DecoderFrameDecision.QUEUE
            }
        }
    }

    fun markConfigQueued() {
        check(cache.isComplete) { "Decoder CSD is incomplete" }
        configPending = false
    }

    fun markFrameQueued(keyframe: Boolean) {
        if (keyframe) awaitingRecoveryKeyframe = false
    }

    fun resetForFlush() {
        awaitingRecoveryKeyframe = true
        configPending = cache.isComplete
    }

    fun clear() {
        cache.clear()
        awaitingRecoveryKeyframe = true
        configPending = false
    }
}

internal object H264AnnexB {
    /** Converts AVC length-prefixed output to the validated Annex-B contract. */
    fun normalize(input: ByteArray): ByteArray? {
        if (input.isEmpty() || input.size > MAX_ACCESS_UNIT_BYTES) return null
        if (hasStartCode(input, 0)) {
            return input.takeIf { parseAnnexB(it) != null }
        }
        for (lengthBytes in intArrayOf(4, 2)) {
            val converted = normalizeLengthPrefixed(input, lengthBytes)
            if (converted != null) return converted
        }
        return null
    }

    fun analyze(input: ByteArray): H264AccessUnitInfo? {
        val annexB = normalize(input) ?: return null
        val nalUnits = parseAnnexB(annexB) ?: return null
        return H264AccessUnitInfo(annexB, nalUnits)
    }

    internal fun parseParameterSets(input: ByteArray): H264ParameterSetValues? {
        if (input.isEmpty() || input.size > H264ParameterSetCache.MAX_CSD_BYTES) return null
        val info = analyze(input) ?: analyzeRawParameterSet(input) ?: return null
        val sps = info.sps
        val pps = info.pps
        if (sps == null && pps == null) return null
        return H264ParameterSetValues(sps, pps)
    }

    internal fun joinNalPayloads(payloads: List<ByteArray>): ByteArray? {
        if (payloads.isEmpty()) return null
        val total = payloads.fold(0L) { sum, payload ->
            sum + 4L + payload.size.toLong()
        }
        if (total <= 0 || total > MAX_ACCESS_UNIT_BYTES) return null
        val result = ByteArray(total.toInt())
        var offset = 0
        payloads.forEach { payload ->
            result[offset++] = 0
            result[offset++] = 0
            result[offset++] = 0
            result[offset++] = 1
            payload.copyInto(result, offset)
            offset += payload.size
        }
        return result
    }

    private fun normalizeLengthPrefixed(input: ByteArray, lengthBytes: Int): ByteArray? {
        val payloads = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < input.size) {
            if (offset + lengthBytes > input.size) return null
            val length = readLength(input, offset, lengthBytes)
            offset += lengthBytes
            if (length <= 0 || offset + length > input.size) return null
            payloads += input.copyOfRange(offset, offset + length)
            offset += length
        }
        return joinNalPayloads(payloads)
    }

    private fun parseAnnexB(input: ByteArray): List<H264NalUnit>? {
        if (!hasStartCode(input, 0)) return null
        val result = mutableListOf<H264NalUnit>()
        var start = 0
        while (start < input.size) {
            val codeLength = startCodeLength(input, start)
            if (codeLength == 0) return null
            val payloadStart = start + codeLength
            val nextStart = findStartCode(input, payloadStart)
            val payloadEnd = nextStart ?: input.size
            if (payloadEnd - payloadStart <= 1) return null
            val type = input[payloadStart].toInt() and 0x1f
            if (type !in 1..23) return null
            result += H264NalUnit(type, input.copyOfRange(payloadStart, payloadEnd))
            if (nextStart == null) break
            start = nextStart
        }
        return result.takeIf { it.isNotEmpty() }
    }

    private fun findStartCode(input: ByteArray, from: Int): Int? {
        var index = from
        while (index + 3 <= input.size) {
            if (hasStartCode(input, index)) return index
            index++
        }
        return null
    }

    private fun hasStartCode(input: ByteArray, offset: Int): Boolean =
        startCodeLength(input, offset) != 0

    private fun startCodeLength(input: ByteArray, offset: Int): Int {
        if (offset < 0 || offset + 3 > input.size) return 0
        if (input[offset] != 0.toByte() || input[offset + 1] != 0.toByte()) return 0
        if (input[offset + 2] == 1.toByte()) return 3
        return if (offset + 4 <= input.size &&
            input[offset + 2] == 0.toByte() && input[offset + 3] == 1.toByte()
        ) {
            4
        } else {
            0
        }
    }

    private fun readLength(input: ByteArray, offset: Int, lengthBytes: Int): Int {
        if (lengthBytes == 4) {
            return ((input[offset].toInt() and 0xff) shl 24) or
                ((input[offset + 1].toInt() and 0xff) shl 16) or
                ((input[offset + 2].toInt() and 0xff) shl 8) or
                (input[offset + 3].toInt() and 0xff)
        }
        return ((input[offset].toInt() and 0xff) shl 8) or
            (input[offset + 1].toInt() and 0xff)
    }

    private fun analyzeRawParameterSet(input: ByteArray): H264AccessUnitInfo? {
        val type = input[0].toInt() and 0x1f
        if (type != 7 && type != 8) return null
        if (type !in 1..23) return null
        if (input.size <= 1) return null
        val payload = input.copyOf()
        val annexB = joinNalPayloads(listOf(payload)) ?: return null
        return H264AccessUnitInfo(annexB, listOf(H264NalUnit(type, payload)))
    }
}

internal fun timestampUsTo90k(timestampUs: Long): Long {
    if (timestampUs <= 0) return 0
    val whole = timestampUs / 1_000L
    val remainder = timestampUs % 1_000L
    if (whole > Long.MAX_VALUE / 90L) return Long.MAX_VALUE
    return (whole * 90L + remainder * 90L / 1_000L).coerceAtMost(Long.MAX_VALUE)
}

internal fun timestamp90kToUs(timestamp90k: Long): Long {
    if (timestamp90k <= 0) return 0
    val whole = timestamp90k / 90L
    val remainder = timestamp90k % 90L
    if (whole > Long.MAX_VALUE / 1_000L) return Long.MAX_VALUE
    return (whole * 1_000L + remainder * 1_000L / 90L).coerceAtMost(Long.MAX_VALUE)
}
