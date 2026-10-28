package com.hejulian.realtime_media_android

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Parses path snapshots. It never accepts media frames. */
internal class GuidanceOverlayChannel(
    private val contextProvider: () -> Context?,
) {
    private var controller: GuidanceOverlayController? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "presentGuidanceOverlay" -> result.success(present(call.arguments))
            "hideGuidanceOverlay" -> {
                controller?.hide()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun close() {
        controller?.hide()
        controller = null
    }

    private fun present(arguments: Any?): Boolean {
        val context = contextProvider() ?: return false
        val snapshot = guidanceSnapshot(arguments) ?: return false
        val current = controller ?: GuidanceOverlayController(
            WindowGuidanceOverlayHost(context),
        ).also { controller = it }
        return current.present(snapshot)
    }
}

internal fun guidanceSnapshot(arguments: Any?): GuidanceOverlaySnapshot? {
    val values = arguments as? Map<*, *> ?: return null
    val width = boundedPositive(values["width"]) ?: return null
    val height = boundedPositive(values["height"]) ?: return null
    val strokes = guidanceStrokes(values["strokes"]) ?: return null
    val pointerX = values["pointer_x"]
    val pointerY = values["pointer_y"]
    val pointer = if (pointerX == null && pointerY == null) {
        null
    } else {
        val x = boundedUnit(pointerX) ?: return null
        val y = boundedUnit(pointerY) ?: return null
        GuidanceOverlayPoint(x, y)
    }
    return GuidanceOverlaySnapshot(width, height, strokes, pointer)
}

private fun guidanceStrokes(value: Any?): List<GuidanceOverlayStroke>? {
    val rows = value as? List<*> ?: return emptyList()
    if (rows.size > 48) return null
    return rows.map { row ->
        val fields = row as? Map<*, *> ?: return null
        val color = (fields["color"] as? Number)?.toInt() ?: return null
        val width = (fields["width"] as? Number)?.toInt() ?: return null
        if (color !in 1..4 || width !in 4..80) return null
        val raw = fields["points"] as? List<*> ?: return null
        if (raw.size > 4096 || raw.size % 2 != 0) return null
        val points = mutableListOf<GuidanceOverlayPoint>()
        var index = 0
        while (index < raw.size) {
            val x = boundedUnit(raw[index]) ?: return null
            val y = boundedUnit(raw[index + 1]) ?: return null
            points.add(GuidanceOverlayPoint(x, y))
            index += 2
        }
        GuidanceOverlayStroke(color, width, points)
    }
}

private fun boundedPositive(value: Any?): Int? {
    val number = (value as? Number)?.toInt() ?: return null
    return number.takeIf { it in 1..16_384 }
}

private fun boundedUnit(value: Any?): Int? {
    val number = (value as? Number)?.toInt() ?: return null
    return number.takeIf { it in 0..65535 }
}
