package com.hejulian.realtime_media_android

/** Worker-confined output lease: hidden consumers retain at most one buffer. */
internal class DecoderPresentationGate(
    private val canRender: () -> Boolean = { true },
    private val release: (index: Int, render: Boolean) -> Unit,
) {
    private var pending: Int? = null

    fun offer(index: Int, visible: Boolean) {
        clear()
        if (visible && canRender()) release(index, true) else pending = index
    }

    fun resume(visible: Boolean) {
        val index = pending ?: return
        if (!visible || !canRender()) return
        pending = null
        release(index, true)
    }

    fun clear() {
        val index = pending ?: return
        pending = null
        release(index, false)
    }
}
