package com.example.ssh_mobile

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Intent
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Full App activity adapter. It does not own media, sessions, or routes. */
internal class ScreenSharePictureInPicture(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val presentation: WindowPresentation,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val coordinator = PictureInPictureCoordinator(Host())

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "setSession") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val args = call.arguments as? Map<*, *>
            coordinator.setVideoAspect(
                (args?.get("width") as? Number)?.toDouble(),
                (args?.get("height") as? Number)?.toDouble(),
            )
            result.success(true)
        }
    }

    fun onUserLeaveHint() = coordinator.onUserLeaveHint()

    fun onModeChanged(active: Boolean) = coordinator.onModeChanged(active)

    fun shouldMoveTaskBack(): Boolean = coordinator.shouldAvoidFinish()

    fun dispose() {
        channel.setMethodCallHandler(null)
        coordinator.setVideoAspect(null, null)
    }

    private inner class Host : PictureInPictureHost {
        override fun sdkAtLeast26(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

        override fun sdkAtLeast31(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

        override fun isActive(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode

        override fun suspendImmersive() {
            presentation.suspendImmersive()
        }

        override fun resumeImmersive() {
            presentation.resumeImmersive()
        }

        override fun apply(aspect: Pair<Int, Int>?, autoEnter: Boolean) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val builder = PictureInPictureParams.Builder()
            if (aspect != null) builder.setAspectRatio(Rational(aspect.first, aspect.second))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(autoEnter && aspect != null)
            }
            try {
                activity.setPictureInPictureParams(builder.build())
            } catch (_: IllegalArgumentException) {
            } catch (_: IllegalStateException) {
            }
        }

        override fun enter(aspect: Pair<Int, Int>): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(aspect.first, aspect.second))
                .build()
            return try {
                activity.enterPictureInPictureMode(params)
            } catch (_: IllegalArgumentException) {
                false
            } catch (_: IllegalStateException) {
                false
            }
        }

        override fun expand() {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                !activity.isInPictureInPictureMode
            ) {
                return
            }
            val intent = Intent(activity, activity.javaClass).addFlags(
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            try {
                activity.startActivity(intent)
            } catch (_: Exception) {
            }
        }

        override fun notifyFlutter(active: Boolean) {
            channel.invokeMethod("onModeChanged", active)
        }
    }

    companion object {
        const val CHANNEL = "ssh_mobile/screen_share_pip"
    }
}
