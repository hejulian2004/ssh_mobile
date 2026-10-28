package com.hejulian.realtime_media_android

import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import kotlin.math.min

internal object GuidanceOverlayRegistry {
    private var host: WindowGuidanceOverlayHost? = null

    fun claim(value: WindowGuidanceOverlayHost) {
        host = value
    }

    fun release(value: WindowGuidanceOverlayHost) {
        if (host === value) host = null
    }

    fun hide() {
        host?.detach()
    }
}

internal class WindowGuidanceOverlayHost(private val context: Context) : GuidanceOverlayHost {
    private var view: GuidanceOverlayView? = null

    override fun canDrawOverlays(): Boolean = Settings.canDrawOverlays(context)

    override fun requestPermission() {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    override fun attach(width: Int, height: Int) {
        if (view != null) return
        val windowManager = context.getSystemService(WindowManager::class.java) ?: return
        val created = GuidanceOverlayView(context)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            GuidanceOverlaySpec.windowType(Build.VERSION.SDK_INT),
            GuidanceOverlaySpec.layoutFlags,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.START
        windowManager.addView(created, params)
        view = created
        GuidanceOverlayRegistry.claim(this)
    }

    override fun detach() {
        val current = view ?: return
        view = null
        val windowManager = context.getSystemService(WindowManager::class.java)
        try {
            windowManager?.removeView(current)
        } catch (_: RuntimeException) {
            // The window is already gone. Stopping the share still succeeds.
        }
        GuidanceOverlayRegistry.release(this)
    }

    override fun render(snapshot: GuidanceOverlaySnapshot) {
        view?.render(snapshot)
    }
}

internal class GuidanceOverlayView(context: Context) : View(context) {
    private var snapshot = GuidanceOverlaySnapshot(0, 0, emptyList(), null)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    fun render(value: GuidanceOverlaySnapshot) {
        snapshot = value
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val rect = guidanceContentRect(width, height, snapshot.width, snapshot.height)
        val shortSide = min(rect.width, rect.height)
        for (stroke in snapshot.strokes) {
            val points = stroke.points
            if (points.isEmpty()) continue
            paint.color = guidanceColor(stroke.color)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = shortSide * stroke.width.coerceIn(4, 80) / 1000f
            if (points.size == 1) {
                canvas.drawCircle(xOf(points[0], rect), yOf(points[0], rect), paint.strokeWidth / 2f, paint)
                continue
            }
            val path = android.graphics.Path()
            path.moveTo(xOf(points[0], rect), yOf(points[0], rect))
            for (point in points.drop(1)) path.lineTo(xOf(point, rect), yOf(point, rect))
            canvas.drawPath(path, paint)
        }
        val pointer = snapshot.pointer ?: return
        paint.style = Paint.Style.FILL
        paint.color = guidanceColor(1)
        canvas.drawCircle(
            xOf(pointer, rect),
            yOf(pointer, rect),
            maxOf(12f, shortSide * 0.02f),
            paint,
        )
    }

    private fun xOf(point: GuidanceOverlayPoint, rect: GuidanceContentRect): Float =
        rect.left + point.x.coerceIn(0, 65535) / 65535f * rect.width

    private fun yOf(point: GuidanceOverlayPoint, rect: GuidanceContentRect): Float =
        rect.top + point.y.coerceIn(0, 65535) / 65535f * rect.height
}

internal fun guidanceColor(index: Int): Int = when (index) {
    2 -> Color.parseColor("#D9FFB300")
    3 -> Color.parseColor("#D943A047")
    4 -> Color.parseColor("#D91E88E5")
    else -> Color.parseColor("#D9E53935")
}
