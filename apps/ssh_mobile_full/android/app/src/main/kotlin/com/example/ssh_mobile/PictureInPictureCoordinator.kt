package com.example.ssh_mobile

import kotlin.math.round

/** Keeps a picture-in-picture ratio inside Android's legal window range. */
internal object PictureInPictureAspect {
    private const val MIN_RATIO = 1.0 / 2.39
    private const val MAX_RATIO = 2.39
    private const val UNITS = 10000

    fun of(width: Double, height: Double): Pair<Int, Int>? {
        if (!width.isFinite() || !height.isFinite() || width <= 0.0 || height <= 0.0) {
            return null
        }
        val ratio = (width / height).coerceIn(MIN_RATIO, MAX_RATIO)
        var wide = round(ratio * UNITS).toInt().coerceAtLeast(1)
        while (wide.toDouble() / UNITS < MIN_RATIO) wide += 1
        while (wide.toDouble() / UNITS > MAX_RATIO) wide -= 1
        return wide to UNITS
    }
}

/** Decisions for entering, publishing, and leaving picture-in-picture. */
internal interface PictureInPictureHost {
    fun sdkAtLeast26(): Boolean
    fun sdkAtLeast31(): Boolean
    fun isActive(): Boolean
    fun suspendImmersive()
    fun resumeImmersive()
    fun apply(aspect: Pair<Int, Int>?, autoEnter: Boolean)
    fun enter(aspect: Pair<Int, Int>): Boolean
    fun expand()
    fun notifyFlutter(active: Boolean)
}

internal class PictureInPictureCoordinator(
    private val host: PictureInPictureHost,
) {
    private var aspect: Pair<Int, Int>? = null
    private var hasPublished = false

    fun setVideoAspect(width: Double?, height: Double?) {
        val next = if (width == null || height == null) {
            null
        } else {
            PictureInPictureAspect.of(width, height)
        }
        val wasEligible = aspect != null
        val changed = !hasPublished || next != aspect
        aspect = next
        if (changed) {
            hasPublished = true
            publish()
        }
        if (wasEligible && next == null && host.isActive()) host.expand()
    }

    /** Drops published eligibility. Teardown must not bring the activity forward. */
    fun release() {
        aspect = null
        hasPublished = true
        publish()
    }

    fun onUserLeaveHint() {
        val ratio = aspect ?: return
        if (!host.sdkAtLeast26() || host.isActive()) return
        host.suspendImmersive()
        if (host.sdkAtLeast31()) return
        if (!host.enter(ratio)) host.resumeImmersive()
    }

    fun onModeChanged(active: Boolean) {
        if (active) host.suspendImmersive() else host.resumeImmersive()
        host.notifyFlutter(active)
    }

    fun shouldAvoidFinish(): Boolean = host.isActive()

    private fun publish() {
        if (!host.sdkAtLeast26()) return
        val ratio = aspect
        if (ratio == null) host.apply(null, false) else host.apply(ratio, host.sdkAtLeast31())
    }
}
