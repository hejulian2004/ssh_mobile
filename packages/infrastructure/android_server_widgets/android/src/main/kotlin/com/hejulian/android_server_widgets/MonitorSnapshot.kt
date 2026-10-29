package com.hejulian.android_server_widgets

enum class MonitorStatus { notConfigured, notStarted, waiting, active, stopped, failed, stale }

data class WidgetServer(val connectionId: String, val displayName: String)

/** One safe observation; invalid values stay unknown rather than becoming zero. */
data class MonitorSnapshot(
    val connectionId: String,
    val displayName: String,
    val sampledAt: Long?,
    val cpuPercent: Double?,
    val memoryPercent: Double?,
    val networkBytesPerSecond: Double?,
    val diskBytesPerSecond: Double?,
    val effectiveIntervalMs: Long,
    val status: MonitorStatus,
) {
    fun statusAt(now: Long): MonitorStatus {
        if (status != MonitorStatus.active || sampledAt == null) return status
        val expiry = (effectiveIntervalMs.coerceIn(1000, 300000) * 3).coerceAtLeast(60000)
        return if (now - sampledAt >= expiry) MonitorStatus.stale else status
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "connectionId" to connectionId,
        "displayName" to displayName,
        "sampledAt" to sampledAt,
        "cpuPercent" to cpuPercent,
        "memoryPercent" to memoryPercent,
        "networkBytesPerSecond" to networkBytesPerSecond,
        "diskBytesPerSecond" to diskBytesPerSecond,
        "effectiveIntervalMs" to effectiveIntervalMs,
        "status" to status.name,
    )

    fun normalized(now: Long): MonitorSnapshot = requireNotNull(fromMap(toMap(), now))

    companion object {
        fun fromMap(map: Map<*, *>, now: Long): MonitorSnapshot? {
            if (integer(map["schemaVersion"]) != 1L) return null
            val id = map["connectionId"] as? String ?: return null
            if (!validConnectionId(id)) return null
            val parsedStatus = MonitorStatus.entries.firstOrNull { it.name == map["status"] }
                ?: MonitorStatus.notConfigured
            val time = integer(map["sampledAt"])?.takeIf {
                it >= 946684800000 && it <= now + 5000 && parsedStatus != MonitorStatus.notConfigured
            }
            fun metric(key: String, percent: Boolean = false): Double? =
                (map[key] as? Number)?.toDouble()?.takeIf {
                    time != null && it.isFinite() && it >= 0 && (!percent || it <= 100)
                }
            val interval = integer(map["effectiveIntervalMs"]) ?: 10000L
            return MonitorSnapshot(
                id,
                safeDisplayName(map["displayName"] as? String ?: ""),
                time,
                metric("cpuPercent", true),
                metric("memoryPercent", true),
                metric("networkBytesPerSecond"),
                metric("diskBytesPerSecond"),
                if (interval <= 0) 10000 else interval.coerceIn(1000, 300000),
                if (time == null && parsedStatus == MonitorStatus.active) MonitorStatus.waiting else parsedStatus,
            )
        }
    }
}

internal fun integer(value: Any?): Long? = when (value) {
    is Int -> value.toLong()
    is Long -> value
    else -> null
}

fun validConnectionId(id: String): Boolean = id.length in 1..128 && id.matches(Regex("[A-Za-z0-9_-]+"))

/** Reject an endpoint/credential label as a whole before truncation. */
fun safeDisplayName(raw: String): String {
    val bounded = raw.take(1024)
    if (Regex("[@:/\\\\=]|\\d+\\.\\d+|\\b[\\w-]+\\.[A-Za-z]{2,}\\b|password|passwd|token|secret|private.?key", RegexOption.IGNORE_CASE)
            .containsMatchIn(bounded)) return "Server"
    val clean = bounded.replace(Regex("[\\u0000-\\u001f\\u007f\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069]"), " ")
        .replace(Regex("\\s+"), " ").trim()
    if (clean.isEmpty()) return "Server"
    return clean.substring(0, clean.offsetByCodePoints(0, minOf(48, clean.codePointCount(0, clean.length))))
}
