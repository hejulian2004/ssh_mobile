package com.example.ssh_mobile

import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Activity window adapter; owns no screen/video/transport resource. */
@Suppress("DEPRECATION")
internal class WindowPresentation(private val window: Window, messenger: BinaryMessenger) {
    private data class Snapshot(
        val legacyFlags: Int,
        val behavior: Int?,
        val statusVisible: Boolean?,
        val navigationVisible: Boolean?,
    )

    private val owner = WindowSnapshotLease(read = ::read, enter = ::hide, restore = ::restore)
    private val channel = MethodChannel(messenger, "ssh_mobile/window_presentation")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "setFullscreen") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val args = call.arguments as? Map<*, *>
            val lease = when (val value = args?.get("lease_id")) {
                is Long -> value
                is Int -> value.toLong()
                else -> null
            }
            val enabled = args?.get("enabled") as? Boolean
            if (lease == null || lease <= 0 || enabled == null) {
                result.error("invalid_argument", "A window lease and intent are required.", null)
            } else if (!owner.setFullscreen(lease, enabled)) {
                result.error("window_presentation_failed", "Window presentation failed.", null)
            } else result.success(true)
        }
    }

    fun refresh() { owner.refresh() }

    fun suspendImmersive() { owner.suspend() }

    fun resumeImmersive() { owner.refresh() }

    fun dispose() {
        channel.setMethodCallHandler(null)
        owner.close()
    }

    private fun read(): Snapshot {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return Snapshot(window.decorView.systemUiVisibility, null, null, null)
        }
        val controller = window.insetsController ?: throw IllegalStateException("No window controller")
        val insets = window.decorView.rootWindowInsets ?: throw IllegalStateException("No window insets")
        return Snapshot(window.decorView.systemUiVisibility, controller.systemBarsBehavior,
            insets.isVisible(WindowInsets.Type.statusBars()),
            insets.isVisible(WindowInsets.Type.navigationBars()))
    }

    private fun hide() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController ?: throw IllegalStateException("No window controller")
            controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsets.Type.systemBars())
        } else {
            window.decorView.systemUiVisibility = window.decorView.systemUiVisibility or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }

    private fun restore(snapshot: Snapshot) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController ?: throw IllegalStateException("No window controller")
            controller.systemBarsBehavior = snapshot.behavior ?: throw IllegalStateException("No saved behavior")
            if (snapshot.statusVisible == true) controller.show(WindowInsets.Type.statusBars())
            else controller.hide(WindowInsets.Type.statusBars())
            if (snapshot.navigationVisible == true) controller.show(WindowInsets.Type.navigationBars())
            else controller.hide(WindowInsets.Type.navigationBars())
        } else window.decorView.systemUiVisibility = snapshot.legacyFlags
    }
}
