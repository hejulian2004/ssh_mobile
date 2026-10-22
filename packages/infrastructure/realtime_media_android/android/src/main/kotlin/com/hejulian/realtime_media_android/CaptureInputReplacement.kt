package com.hejulian.realtime_media_android

/** Serial worker transaction borrowing the existing display and owner. */
internal fun replaceCaptureInput(
    isActive: () -> Boolean,
    detachSurface: () -> Unit,
    releaseEncoder: () -> Unit,
    createEncoder: () -> Unit,
    resizeDisplay: () -> Unit,
    attachSurface: () -> Unit,
): Boolean {
    if (!isActive()) return false
    detachSurface()
    if (!isActive()) return false
    releaseEncoder()
    if (!isActive()) return false
    createEncoder()
    if (!isActive()) return false
    resizeDisplay()
    if (!isActive()) return false
    attachSurface()
    return true
}
