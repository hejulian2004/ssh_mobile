package com.hejulian.realtime_media_android

/** Orders codec input/output work without owning a codec or frame buffer. */
internal class DecoderOutputPump(
    private val isActive: () -> Boolean,
    private val submitInput: () -> Boolean,
    private val readOutput: () -> Int,
    private val renderOutput: (Int) -> Unit,
) {
    fun step(): Boolean {
        if (!isActive()) return false
        drain()
        if (!isActive()) return false
        val submitted = submitInput()
        if (submitted) drain()
        return submitted
    }

    private fun drain() {
        repeat(32) {
            if (!isActive()) return
            val index = readOutput()
            when {
                index >= 0 -> renderOutput(index)
                index == -1 -> return
                index == -2 || index == -3 -> Unit
                else -> throw IllegalStateException("Unexpected decoder output status")
            }
        }
    }
}
