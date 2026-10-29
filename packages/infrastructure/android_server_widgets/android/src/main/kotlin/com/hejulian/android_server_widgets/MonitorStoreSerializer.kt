package com.hejulian.android_server_widgets

import androidx.datastore.core.CorruptionException
import androidx.datastore.core.Serializer
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

data class MonitorStore(
    val session: String = "",
    val sequence: Long = 0,
    val servers: List<WidgetServer> = emptyList(),
    val snapshots: Map<String, MonitorSnapshot> = emptyMap(),
)

/** Versioned 128 KiB envelope; read bounds precede allocation of any records. */
object MonitorStoreSerializer : Serializer<MonitorStore> {
    override val defaultValue = MonitorStore()
    private const val maxBytes = 131072

    override suspend fun readFrom(input: InputStream): MonitorStore {
        val bytes = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (bytes.size() + count > maxBytes) throw CorruptionException("Widget snapshot exceeds bound")
            bytes.write(buffer, 0, count)
        }
        try {
            val data = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
            require(data.readInt() == 1)
            val session = data.readUTF().also { require(it.length <= 64) }
            val sequence = data.readLong().also { require(it >= 0) }
            val count = data.readInt().also { require(it in 0..100) }
            val servers = mutableListOf<WidgetServer>()
            val snapshots = mutableMapOf<String, MonitorSnapshot>()
            repeat(count) {
                val id = data.readUTF().also { require(validConnectionId(it)) }
                require(servers.none { it.connectionId == id })
                val name = safeDisplayName(data.readUTF())
                servers.add(WidgetServer(id, name))
                if (data.readBoolean()) {
                    require(data.readInt() == 1)
                    val sample = MonitorSnapshot(
                        id, name, if (data.readBoolean()) data.readLong() else null,
                        data.optionalDouble(), data.optionalDouble(), data.optionalDouble(), data.optionalDouble(),
                        data.readLong(), MonitorStatus.valueOf(data.readUTF()),
                    ).normalized(Long.MAX_VALUE - 5000)
                    snapshots[id] = sample
                }
            }
            require(data.read() == -1)
            return MonitorStore(session, sequence, servers.toList(), snapshots.toMap())
        } catch (error: IOException) {
            throw CorruptionException("Invalid widget snapshot", error)
        } catch (error: IllegalArgumentException) {
            throw CorruptionException("Unsupported widget snapshot", error)
        }
    }

    override suspend fun writeTo(t: MonitorStore, output: OutputStream) {
        require(t.session.length <= 64 && t.sequence >= 0 && t.servers.size <= 100)
        require(t.servers.map { it.connectionId }.toSet().size == t.servers.size)
        require(t.snapshots.keys.all { id -> t.servers.any { it.connectionId == id } })
        val bytes = ByteArrayOutputStream()
        val data = DataOutputStream(bytes)
        data.writeInt(1)
        data.writeUTF(t.session)
        data.writeLong(t.sequence)
        data.writeInt(t.servers.size)
        for (server in t.servers) {
            require(validConnectionId(server.connectionId))
            data.writeUTF(server.connectionId)
            data.writeUTF(safeDisplayName(server.displayName))
            val sample = t.snapshots[server.connectionId]?.normalized(Long.MAX_VALUE - 5000)
            data.writeBoolean(sample != null)
            if (sample != null) {
                data.writeInt(1)
                data.writeBoolean(sample.sampledAt != null)
                sample.sampledAt?.let(data::writeLong)
                data.optionalDouble(sample.cpuPercent)
                data.optionalDouble(sample.memoryPercent)
                data.optionalDouble(sample.networkBytesPerSecond)
                data.optionalDouble(sample.diskBytesPerSecond)
                data.writeLong(sample.effectiveIntervalMs)
                data.writeUTF(sample.status.name)
            }
        }
        require(bytes.size() <= maxBytes)
        output.write(bytes.toByteArray())
    }

    private fun DataInputStream.optionalDouble(): Double? = if (readBoolean()) readDouble() else null
    private fun DataOutputStream.optionalDouble(value: Double?) {
        writeBoolean(value != null)
        value?.let(::writeDouble)
    }
}
