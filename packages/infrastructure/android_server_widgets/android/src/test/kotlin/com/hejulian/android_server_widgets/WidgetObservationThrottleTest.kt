package com.hejulian.android_server_widgets

import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class WidgetObservationThrottleTest {
    private fun observation(
        time: Long = 1000, cpu: Double = 42.0, status: MonitorStatus = MonitorStatus.active,
        name: String = "Compute A", id: String = "a",
    ) = WidgetObservation(id, WidgetServer(id, name), MonitorSnapshot(
        id, name, 1793275200000L + time, cpu, 63.0, 1024.0, 2048.0, 10000, status,
    ))

    @Test fun ordinarySamplesAreThrottledWhileStatusNameDeletionAndBindingStayImmediate() = runBlocking {
        var now = 1000L
        val source = flow {
            emit(observation())
            now = 2000; emit(observation(now, 43.0))
            now = 15999; emit(observation(now, 43.0))
            now = 16000; emit(observation(now, 44.0))
            now = 16001; emit(observation(now, 44.0, MonitorStatus.stopped))
            now = 16002; emit(observation(now, 44.0, MonitorStatus.stopped, "Renamed"))
            now = 16003; emit(WidgetObservation("a", null, null))
            now = 16004; emit(WidgetObservation("a", null, null))
            now = 16005; emit(WidgetObservation(null, null, null))
            now = 16006; emit(WidgetObservation(null, null, null))
            now = 16007; emit(observation(now, 1.0, id = "b"))
        }
        val displayed = source.limitWidgetRefresh(7, clock = { now }).toList()
        assertEquals(listOf(42.0, 44.0, 44.0, 44.0, null, null, 1.0), displayed.map { it.snapshot?.cpuPercent })
        assertEquals(MonitorStatus.stopped, displayed[2].snapshot!!.status)
        assertEquals("Renamed", displayed[3].server!!.displayName)
        assertEquals("a", displayed[4].connectionId)
        assertNull(displayed[5].connectionId)
        assertEquals("b", displayed.last().connectionId)
    }

    @Test fun firstSampleAndFreshCollectorDoNotWaitOrBorrowAnotherCompositionBudget() = runBlocking {
        var now = 1000L
        val source = flow {
            emit(WidgetObservation("a", WidgetServer("a", "Compute A"), null))
            now = 1001; emit(observation(now))
            now = 1002; emit(observation(now, 43.0))
        }.limitWidgetRefresh(7, clock = { now })
        val first = source.toList()
        now = 1000
        val nextComposition = source.toList()
        assertEquals(first, nextComposition)
        assertEquals(2, first.size)
        assertNull(first.first().snapshot)
        assertEquals(42.0, first.last().snapshot!!.cpuPercent!!, 0.0)
    }
}
