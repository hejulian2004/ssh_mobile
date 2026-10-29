package com.hejulian.android_server_widgets

import androidx.datastore.core.DataStore
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.flow.first

/** Storage owner only: every update is one durable DataStore transaction. */
class MonitorSnapshotRepository(
    private val dataStore: DataStore<MonitorStore>,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    suspend fun beginSession(): String {
        val session = UUID.randomUUID().toString()
        dataStore.updateData { current ->
            current.copy(session = session, sequence = 0, snapshots = current.snapshots.mapValues { (_, value) ->
                if (value.status == MonitorStatus.active || value.status == MonitorStatus.waiting)
                    value.copy(status = MonitorStatus.stopped) else value
            })
        }
        return session
    }

    suspend fun synchronize(write: WidgetWrite): Boolean = synchronize(
        write.session, write.sequence, write.servers, write.snapshots, write.invalidatedBefore, write.reset,
    )

    suspend fun synchronize(
        session: String,
        sequence: Long,
        servers: List<WidgetServer>,
        snapshots: List<MonitorSnapshot>,
        invalidatedBefore: Map<String, Long>,
        reset: Boolean,
    ): Boolean {
        require(session.length in 1..64 && sequence > 0)
        require(servers.size <= 100 && snapshots.size <= 100 && invalidatedBefore.size <= 100)
        val ids = servers.map { it.connectionId }.toSet()
        require(ids.size == servers.size && ids.all(::validConnectionId))
        require(snapshots.map { it.connectionId }.toSet().size == snapshots.size)
        require(snapshots.all { it.connectionId in ids })
        require(invalidatedBefore.all { (id, time) -> validConnectionId(id) && time >= 0 })
        val catalog = servers.map { WidgetServer(it.connectionId, safeDisplayName(it.displayName)) }
        var accepted = false
        dataStore.updateData { current ->
            if (current.session != session || sequence <= current.sequence) return@updateData current
            val next = if (reset) mutableMapOf() else current.snapshots.filter { (id, sample) ->
                id in ids && (sample.sampledAt ?: 0) >= (invalidatedBefore[id] ?: 0)
            }.toMutableMap()
            for (incoming in snapshots) {
                val sample = incoming.normalized(clock())
                val cutoff = invalidatedBefore[sample.connectionId] ?: 0
                val previous = next[sample.connectionId]
                next[sample.connectionId] = if (
                    sample.sampledAt == null && previous?.sampledAt != null &&
                    sample.status in setOf(MonitorStatus.notStarted, MonitorStatus.stopped, MonitorStatus.failed)
                ) previous.copy(status = sample.status, effectiveIntervalMs = sample.effectiveIntervalMs)
                else if (sample.sampledAt != null && sample.sampledAt < cutoff) sample.copy(
                    sampledAt = null, cpuPercent = null, memoryPercent = null,
                    networkBytesPerSecond = null, diskBytesPerSecond = null, status = MonitorStatus.notStarted,
                ) else sample
            }
            for (server in catalog) {
                next[server.connectionId]?.let { next[server.connectionId] = it.copy(displayName = server.displayName) }
            }
            accepted = true
            MonitorStore(session, sequence, catalog, next.toMap())
        }
        return accepted
    }

    suspend fun snapshotFor(connectionId: String): MonitorSnapshot? {
        if (!validConnectionId(connectionId)) return null
        val sample = readSafe().snapshots[connectionId]?.normalized(clock()) ?: return null
        return sample.copy(status = sample.statusAt(clock()))
    }

    suspend fun servers(): List<WidgetServer> = readSafe().servers.toList()

    private suspend fun readSafe(): MonitorStore = try {
        dataStore.data.first()
    } catch (_: IOException) {
        // A read failure may display no data, but never substitutes a writable
        // in-memory database. All writes continue to report their I/O failure.
        MonitorStore()
    }
}
