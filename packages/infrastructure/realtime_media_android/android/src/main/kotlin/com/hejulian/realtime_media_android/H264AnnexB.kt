package com.hejulian.realtime_media_android

import java.nio.ByteBuffer

internal object H264AnnexB {
    private const val MAX_ACCESS_UNIT_BYTES = 4 * 1024 * 1024

    /** Converts AVC length-prefixed output to the Annex-B contract. */
    fun normalize(input: ByteArray): ByteArray? {
        if (input.isEmpty() || input.size > MAX_ACCESS_UNIT_BYTES) return null
        if (hasStartCode(input, 0)) return input

        for (lengthBytes in intArrayOf(4, 2)) {
            val output = ByteArray(input.size + 4 * 16)
            var inputOffset = 0
            var outputOffset = 0
            var nalCount = 0
            while (inputOffset + lengthBytes <= input.size) {
                val nalLength = readLength(input, inputOffset, lengthBytes)
                inputOffset += lengthBytes
                if (nalLength <= 0 || inputOffset + nalLength > input.size) break
                if (outputOffset + 4 + nalLength > MAX_ACCESS_UNIT_BYTES) return null
                if (outputOffset + 4 + nalLength > output.size) {
                    val expanded = ByteArray((output.size * 2).coerceAtMost(MAX_ACCESS_UNIT_BYTES))
                    output.copyInto(expanded, 0, 0, outputOffset)
                    return normalizeWithBuffer(input, lengthBytes, expanded)
                }
                output[outputOffset++] = 0
                output[outputOffset++] = 0
                output[outputOffset++] = 0
                output[outputOffset++] = 1
                input.copyInto(output, outputOffset, inputOffset, inputOffset + nalLength)
                outputOffset += nalLength
                inputOffset += nalLength
                nalCount++
            }
            if (nalCount > 0 && inputOffset == input.size) return output.copyOf(outputOffset)
        }
        return null
    }

    private fun normalizeWithBuffer(input: ByteArray, lengthBytes: Int, initial: ByteArray): ByteArray? {
        var output = initial
        var inputOffset = 0
        var outputOffset = 0
        var nalCount = 0
        while (inputOffset + lengthBytes <= input.size) {
            val nalLength = readLength(input, inputOffset, lengthBytes)
            inputOffset += lengthBytes
            if (nalLength <= 0 || inputOffset + nalLength > input.size) return null
            if (outputOffset + 4 + nalLength > MAX_ACCESS_UNIT_BYTES) return null
            if (outputOffset + 4 + nalLength > output.size) {
                val size = (output.size * 2).coerceAtMost(MAX_ACCESS_UNIT_BYTES)
                if (size <= output.size) return null
                output = output.copyOf(size)
            }
            output[outputOffset++] = 0
            output[outputOffset++] = 0
            output[outputOffset++] = 0
            output[outputOffset++] = 1
            input.copyInto(output, outputOffset, inputOffset, inputOffset + nalLength)
            outputOffset += nalLength
            inputOffset += nalLength
            nalCount++
        }
        return if (nalCount > 0 && inputOffset == input.size) output.copyOf(outputOffset) else null
    }

    private fun hasStartCode(input: ByteArray, offset: Int): Boolean =
        offset + 3 <= input.size &&
            input[offset] == 0.toByte() &&
            input[offset + 1] == 0.toByte() &&
            (input[offset + 2] == 1.toByte() ||
                (offset + 4 <= input.size && input[offset + 2] == 0.toByte() && input[offset + 3] == 1.toByte()))

    private fun readLength(input: ByteArray, offset: Int, lengthBytes: Int): Int {
        val buffer = ByteBuffer.wrap(input, offset, lengthBytes)
        return if (lengthBytes == 4) buffer.int else buffer.short.toInt() and 0xffff
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
