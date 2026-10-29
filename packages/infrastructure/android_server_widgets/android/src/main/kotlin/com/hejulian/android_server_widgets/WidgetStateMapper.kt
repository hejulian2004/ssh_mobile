package com.hejulian.android_server_widgets

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

enum class WidgetStatus { notConfigured, notStarted, waiting, active, stopped, failed, stale, removed }

data class WidgetDisplayState(
    val displayName: String, val cpu: String, val memory: String, val network: String, val disk: String,
    val cpuProgress: Float?, val memoryProgress: Float?, val status: WidgetStatus,
    val sampledAt: String, val compactSampledAt: String,
)

/** Pure presentation mapping. It observes cached facts and absolute time only. */
object WidgetStateMapper {
    fun map(
        connectionId: String?, server: WidgetServer?, snapshot: MonitorSnapshot?, now: Long,
        locale: Locale = Locale.getDefault(), zone: TimeZone = TimeZone.getDefault(),
    ): WidgetDisplayState {
        val sample = snapshot?.takeIf { it.connectionId == connectionId && server != null }?.normalized(now)
        val status = when {
            connectionId == null -> WidgetStatus.notConfigured
            server == null -> WidgetStatus.removed
            sample == null -> WidgetStatus.notStarted
            else -> WidgetStatus.valueOf(sample.statusAt(now).name)
        }
        fun percent(value: Double?) = value?.let { String.format(locale, "%.0f%%", it) } ?: "—"
        fun time(pattern: String) = sample?.sampledAt?.let {
            SimpleDateFormat(pattern, locale).apply { timeZone = zone }.format(Date(it))
        } ?: "—"
        return WidgetDisplayState(
            server?.let { safeDisplayName(it.displayName) } ?: "SSH Mobile",
            percent(sample?.cpuPercent), percent(sample?.memoryPercent),
            rate(sample?.networkBytesPerSecond, locale), rate(sample?.diskBytesPerSecond, locale),
            sample?.cpuPercent?.let { (it / 100).toFloat() },
            sample?.memoryPercent?.let { (it / 100).toFloat() }, status,
            time("yyyy-MM-dd HH:mm"), time("MM-dd HH:mm"),
        )
    }

    private fun rate(value: Double?, locale: Locale): String {
        if (value == null) return "—"
        if (value >= 1125899906842624.0) return "≥1 PiB/s"
        val units = listOf("B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s")
        var scaled = value
        var index = 0
        while (scaled >= 1024 && index < units.lastIndex) { scaled /= 1024; index++ }
        return String.format(locale, if (index == 0) "%.0f %s" else "%.1f %s", scaled, units[index])
    }
}
