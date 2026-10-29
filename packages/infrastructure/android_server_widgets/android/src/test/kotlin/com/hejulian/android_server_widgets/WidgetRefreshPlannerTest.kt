package com.hejulian.android_server_widgets

import org.junit.Assert.*
import org.junit.Test

class WidgetRefreshPlannerTest {
    private fun state(time: Long? = 1000, status: MonitorStatus = MonitorStatus.active, name: String = "Compute A") =
        WidgetRefreshState(name, status, time, 10000)

    @Test fun refreshesOnlyAffectedInstancesAndThrottlesSamplesPerInstance() {
        val planner = WidgetRefreshPlanner()
        val mappings = mapOf(1 to "a", 2 to "a", 3 to "b")
        assertEquals(setOf(1, 2), planner.plan(mappings, mapOf("a" to state()), 1000, setOf("a")))
        assertTrue(planner.plan(mappings, mapOf("a" to state()), 2000, setOf("a")).isEmpty())
        assertTrue(planner.plan(mappings, mapOf("a" to state(2000)), 2000, setOf("a")).isEmpty())
        assertEquals(setOf(3), planner.plan(mappings, mapOf("b" to state()), 2000, setOf("b")))
        assertEquals(setOf(1, 2), planner.plan(mappings, mapOf("a" to state(16000)), 16000, setOf("a")))
        assertEquals(setOf(1, 2), planner.plan(mappings, mapOf("a" to state(17000, MonitorStatus.stopped)), 17000, setOf("a")))
        assertEquals(setOf(1, 2), planner.plan(mappings, mapOf("a" to state(17000, MonitorStatus.stopped, "Renamed")), 17001, setOf("a")))
        assertEquals(setOf(1, 2), planner.plan(mappings, emptyMap(), 17002, setOf("a")))
        assertTrue(planner.plan(mappings, emptyMap(), 17003, setOf("a")).isEmpty())
    }

    @Test fun firstSampleReconfigurationClockChangeAndFailedRenderCanRefreshImmediately() {
        val planner = WidgetRefreshPlanner()
        assertEquals(setOf(1), planner.plan(mapOf(1 to "a"), mapOf("a" to state(null, MonitorStatus.waiting)), 1000))
        assertEquals(setOf(1), planner.plan(mapOf(1 to "a"), mapOf("a" to state(1100)), 1100))
        assertEquals(setOf(1), planner.plan(mapOf(1 to "b"), mapOf("b" to state(1100)), 1101))
        assertEquals(setOf(1), planner.plan(mapOf(1 to "b"), mapOf("b" to state(1200)), 100))
        assertEquals(setOf(1), planner.plan(mapOf(1 to "b"), mapOf("b" to state(1200)), 101, force = true))
        planner.invalidate(setOf(1))
        assertEquals(setOf(1), planner.plan(mapOf(1 to "b"), mapOf("b" to state(1200)), 102))
        planner.plan(emptyMap(), emptyMap(), 103)
        assertEquals(setOf(1), planner.plan(mapOf(1 to "b"), mapOf("b" to state(1200)), 104))
    }
}
