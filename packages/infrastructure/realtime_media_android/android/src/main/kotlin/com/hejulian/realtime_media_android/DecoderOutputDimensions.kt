package com.hejulian.realtime_media_android

/** The visible output rectangle, rather than a running maximum of input sizes. */
internal fun decoderOutputDimensions(
    width: Int,
    height: Int,
    left: Int? = null,
    right: Int? = null,
    top: Int? = null,
    bottom: Int? = null,
): Pair<Int, Int>? {
    if (width <= 0 || height <= 0) return null
    if (left == null && right == null && top == null && bottom == null) return width to height
    if (left == null || right == null || top == null || bottom == null) return null
    if (left < 0 || top < 0 || right < left || bottom < top ||
        right >= width || bottom >= height) return null
    return (right - left + 1) to (bottom - top + 1)
}
