package com.hejulian.realtime_media_android

/**
 * Retains at most one native frame while MediaCodec applies input
 * backpressure. The pull callback is never invoked again until the retained
 * frame is queued or explicitly discarded.
 */
internal class PendingDecoderFrame<T> {
    private var value: T? = null

    val hasPending: Boolean
        get() = value != null

    fun acquire(pull: () -> T?): T? {
        val current = value
        if (current != null) return current
        val next = pull() ?: return null
        value = next
        return next
    }

    fun markQueued() {
        check(value != null) { "No decoder frame is pending" }
        value = null
    }

    fun clear() {
        value = null
    }
}
