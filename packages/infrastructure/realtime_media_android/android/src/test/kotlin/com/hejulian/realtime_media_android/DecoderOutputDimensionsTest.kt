package com.hejulian.realtime_media_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DecoderOutputDimensionsTest {
    @Test
    fun usesCurrentOutputAndCropInsteadOfLargestPreviousDimensions() {
        assertEquals(1080 to 1920, decoderOutputDimensions(1088, 1920, 0, 1079, 0, 1919))
        assertEquals(1920 to 1080, decoderOutputDimensions(1920, 1088, 0, 1919, 0, 1079))
        assertEquals(1080 to 1920, decoderOutputDimensions(1080, 1920))
    }

    @Test
    fun invalidOrPartialCropCannotPublishAnInvalidAspectRatio() {
        assertNull(decoderOutputDimensions(0, 1080))
        assertNull(decoderOutputDimensions(1920, -1))
        assertNull(decoderOutputDimensions(1920, 1080, 0, null, 0, 1079))
        assertNull(decoderOutputDimensions(1920, 1080, -1, 1919, 0, 1079))
        assertNull(decoderOutputDimensions(1920, 1080, 0, 1920, 0, 1079))
        assertNull(decoderOutputDimensions(1920, 1080, 10, 9, 0, 1079))
        assertNull(decoderOutputDimensions(1920, 1080, 0, 1919, 0, 1080))
        assertNull(decoderOutputDimensions(1920, 1080, 0, 1919, 2, 1))
    }
}
