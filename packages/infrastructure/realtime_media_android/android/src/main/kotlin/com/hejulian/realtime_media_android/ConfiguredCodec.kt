package com.hejulian.realtime_media_android

/** Transfers only a configured codec, releasing failed configuration attempts. */
internal fun <Candidate, Codec : Any> acquireConfiguredCodec(
    candidates: Iterable<Candidate>,
    create: (Candidate) -> Codec,
    configure: (Codec) -> Unit,
    release: (Codec) -> Unit,
): Codec? {
    for (candidate in candidates) {
        val codec = try { create(candidate) } catch (_: Exception) { continue }
        try {
            configure(codec)
            return codec
        } catch (_: Exception) {
            try { release(codec) } catch (_: Exception) {
                // Cleanup could not be confirmed: do not allocate a replacement.
                return null
            }
        }
    }
    return null
}
