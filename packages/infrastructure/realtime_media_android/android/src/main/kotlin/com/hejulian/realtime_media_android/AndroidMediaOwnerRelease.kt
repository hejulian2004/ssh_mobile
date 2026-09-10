package com.hejulian.realtime_media_android

/**
 * Stops a native owner before closing it. A failed stop keeps the owner open
 * so the caller can retry the complete release sequence.
 */
internal fun releaseNativeOwner(
    stopOwner: () -> Int,
    closeOwner: () -> Int,
): Int {
    val stopStatus = stopOwner()
    if (stopStatus != 0 && stopStatus != -12) return stopStatus

    val closeStatus = closeOwner()
    return if (closeStatus == 0 || closeStatus == -12) 0 else closeStatus
}
