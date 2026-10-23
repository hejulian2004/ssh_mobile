package com.hejulian.realtime_media_android

/** Main-thread request owns one deadline and exactly one readiness completion. */
internal class ForegroundReadinessRequest(
    private val onComplete: (Int) -> Unit,
    private val scheduleTimeout: (() -> Unit) -> (() -> Unit),
) {
    companion object {
        const val READY = 0
        const val DENIED = 1
        const val FAILED = 2
        const val CANCELLED = 3
        const val TIMED_OUT = 4
    }
    private var finished = false
    private var cancelTimeout: (() -> Unit)? = null

    fun start(begin: ((Int) -> Unit) -> Unit) {
        if (finished) return
        try {
            cancelTimeout = scheduleTimeout { complete(TIMED_OUT) }
            if (finished) {
                cancelTimeout?.invoke()
                cancelTimeout = null
                return
            }
            begin(::complete)
        } catch (_: SecurityException) {
            complete(DENIED)
        } catch (_: Exception) {
            complete(FAILED)
        }
    }

    fun complete(code: Int) {
        if (finished) return
        finished = true
        val cancel = cancelTimeout
        cancelTimeout = null
        try { cancel?.invoke() } finally { onComplete(code) }
    }

    fun cancel() = complete(CANCELLED)
}
