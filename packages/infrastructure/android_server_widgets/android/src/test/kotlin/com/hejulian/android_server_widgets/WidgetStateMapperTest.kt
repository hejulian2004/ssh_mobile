package com.hejulian.android_server_widgets

import java.util.Locale
import java.util.TimeZone
import org.junit.Assert.*
import org.junit.Test

class WidgetStateMapperTest {
    private val now = 1793275200000L
    private val server = WidgetServer("a", "Compute A")
    private fun sample(status: MonitorStatus = MonitorStatus.active) = MonitorSnapshot(
        "a", "Compute A", now, 42.4, 63.0, 1024.0, 2048.0, 10000, status,
    )
    private fun map(snapshot: MonitorSnapshot?, time: Long = now) = WidgetStateMapper.map(
        "a", server, snapshot, time, Locale.US, TimeZone.getTimeZone("UTC"),
    )

    @Test fun mapsRealMetricsAndAbsoluteTimeWithoutStartingAnything() {
        val view = map(sample())
        assertEquals("Compute A", view.displayName)
        assertEquals("42%", view.cpu)
        assertEquals("63%", view.memory)
        assertEquals("1.0 KiB/s", view.network)
        assertEquals("2.0 KiB/s", view.disk)
        assertEquals(0.424f, view.cpuProgress!!, 0.0001f)
        assertEquals(0.63f, view.memoryProgress!!, 0.0001f)
        assertEquals(WidgetStatus.active, view.status)
        assertEquals("2026-10-29 12:00", view.sampledAt)
        assertEquals("10-29 12:00", view.compactSampledAt)
    }

    @Test fun missingSelectionDeletedServerAndMissingSnapshotRemainDistinct() {
        assertEquals(WidgetStatus.notConfigured, WidgetStateMapper.map(null, null, null, now).status)
        assertEquals(WidgetStatus.removed, WidgetStateMapper.map("a", null, sample(), now).status)
        val missing = map(null)
        assertEquals(WidgetStatus.notStarted, missing.status)
        assertEquals("—", missing.cpu)
        assertEquals("—", missing.sampledAt)
        assertNull(missing.cpuProgress)
    }

    @Test fun invalidValuesAndWrongServerNeverBecomeFakeZeroReadings() {
        val invalid = map(sample().copy(cpuPercent = Double.NaN, memoryPercent = 101.0,
            networkBytesPerSecond = -1.0, diskBytesPerSecond = Double.POSITIVE_INFINITY))
        assertEquals(listOf("—", "—", "—", "—"), listOf(invalid.cpu, invalid.memory, invalid.network, invalid.disk))
        assertNull(invalid.cpuProgress)
        assertNull(invalid.memoryProgress)
        assertEquals(WidgetStatus.notStarted, map(sample().copy(connectionId = "other")).status)
        assertEquals(WidgetStatus.waiting, map(sample().copy(sampledAt = now + 60000)).status)
        assertEquals("0 B/s", map(sample().copy(networkBytesPerSecond = 0.0)).network)
    }

    @Test fun statusTransitionsPreserveLastSampleTimeAndFiveMinuteExpiry() {
        for (status in MonitorStatus.entries) {
            val view = map(sample(status))
            assertEquals(WidgetStatus.valueOf(status.name), view.status)
            if (status != MonitorStatus.notConfigured) assertEquals("2026-10-29 12:00", view.sampledAt)
        }
        val slow = sample().copy(effectiveIntervalMs = 300000)
        assertEquals(WidgetStatus.active, map(slow, now + 899999).status)
        assertEquals(WidgetStatus.stale, map(slow, now + 900000).status)
        assertEquals("2026-10-29 12:00", map(slow, now + 900000).sampledAt)
        assertEquals(WidgetStatus.stopped, map(sample(MonitorStatus.stopped), now + 900000).status)
    }

    @Test fun ratesAreBoundedAcrossUnitsAndLocalizationUsesTheChosenTimeZone() {
        val values = listOf(1.0, 1024.0, 1048576.0, 1073741824.0, 1099511627776.0,
            1125899906842624.0, Double.MAX_VALUE)
        val expected = listOf("1 B/s", "1.0 KiB/s", "1.0 MiB/s", "1.0 GiB/s", "1.0 TiB/s", "≥1 PiB/s", "≥1 PiB/s")
        assertEquals(expected, values.map { map(sample().copy(networkBytesPerSecond = it)).network })
        val localized = WidgetStateMapper.map("a", server, sample(), now, Locale.GERMANY, TimeZone.getTimeZone("GMT+08:00"))
        assertEquals("1,0 KiB/s", localized.network)
        assertEquals("2026-10-29 20:00", localized.sampledAt)
    }
}
