package com.hejulian.realtime_media_android

internal data class GuidanceOverlayPoint(val x: Int, val y: Int)

internal data class GuidanceOverlayStroke(
    val color: Int,
    val width: Int,
    val points: List<GuidanceOverlayPoint>,
)

internal data class GuidanceOverlaySnapshot(
    val width: Int,
    val height: Int,
    val strokes: List<GuidanceOverlayStroke>,
    val pointer: GuidanceOverlayPoint?,
)

internal data class GuidanceContentRect(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
)

internal object GuidanceOverlaySpec {
    const val overlayType = 2038
    const val legacyType = 2002
    const val flagNotFocusable = 8
    const val flagNotTouchable = 16
    const val flagNotTouchModal = 32
    const val flagLayoutInScreen = 256
    const val layoutFlags =
        flagNotFocusable or flagNotTouchable or flagNotTouchModal or flagLayoutInScreen

    fun windowType(sdkInt: Int): Int = if (sdkInt >= 26) overlayType else legacyType
}

internal fun guidanceContentRect(
    viewWidth: Int,
    viewHeight: Int,
    frameWidth: Int,
    frameHeight: Int,
): GuidanceContentRect {
    if (viewWidth <= 0 || viewHeight <= 0 || frameWidth <= 0 || frameHeight <= 0) {
        return GuidanceContentRect(0f, 0f, viewWidth.coerceAtLeast(0).toFloat(), viewHeight.coerceAtLeast(0).toFloat())
    }
    val scale = minOf(viewWidth.toFloat() / frameWidth, viewHeight.toFloat() / frameHeight)
    val width = frameWidth * scale
    val height = frameHeight * scale
    return GuidanceContentRect((viewWidth - width) / 2f, (viewHeight - height) / 2f, width, height)
}

internal interface GuidanceOverlayHost {
    fun canDrawOverlays(): Boolean
    fun requestPermission()
    fun attach(width: Int, height: Int)
    fun detach()
    fun render(snapshot: GuidanceOverlaySnapshot)
}

/** Pure window policy. Permission denial never attaches a window. */
internal class GuidanceOverlayController(private val host: GuidanceOverlayHost) {
    var visible: Boolean = false
        private set
    private var permissionRequested = false

    fun present(snapshot: GuidanceOverlaySnapshot): Boolean {
        if (snapshot.width <= 0 || snapshot.height <= 0) return false
        if (!host.canDrawOverlays()) {
            if (!permissionRequested) {
                permissionRequested = true
                host.requestPermission()
            }
            return false
        }
        if (!visible) {
            host.attach(snapshot.width, snapshot.height)
            visible = true
        }
        host.render(snapshot)
        return true
    }

    fun hide() {
        if (!visible) return
        host.detach()
        visible = false
    }
}
