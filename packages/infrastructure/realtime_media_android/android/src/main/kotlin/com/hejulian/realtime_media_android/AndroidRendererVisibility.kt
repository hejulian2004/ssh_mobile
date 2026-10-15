package com.hejulian.realtime_media_android

import android.app.Activity
import android.app.Application
import android.os.Bundle

/** Observes only the engine's Activity; it never stops a native media owner. */
internal class AndroidRendererVisibility : Application.ActivityLifecycleCallbacks {
    private val lock = Any()
    private var activity: Activity? = null
    private var visible = false

    fun attach(next: Activity) {
        detach()
        synchronized(lock) {
            activity = next
            visible = next.hasWindowFocus()
            next.application.registerActivityLifecycleCallbacks(this)
        }
    }

    fun detach() {
        synchronized(lock) {
            activity?.application?.unregisterActivityLifecycleCallbacks(this)
            activity = null
            visible = false
        }
    }

    // Never hold an Activity lifecycle lock while entering the native codec.
    fun present(block: (Boolean) -> Unit) {
        val current = synchronized(lock) { visible }
        block(current)
    }

    override fun onActivityResumed(candidate: Activity) = update(candidate, true)
    // API 29+ runs this before Flutter pauses its texture consumer. Older
    // Android versions still use the ordinary pause callback below.
    override fun onActivityPrePaused(candidate: Activity) = update(candidate, false)
    override fun onActivityPaused(candidate: Activity) = update(candidate, false)
    override fun onActivityStopped(candidate: Activity) = update(candidate, false)
    override fun onActivityDestroyed(candidate: Activity) = update(candidate, false)

    private fun update(candidate: Activity, next: Boolean) {
        synchronized(lock) { if (activity === candidate) visible = next }
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
}
