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

/** Small versioned selections file; it contains only widget and connection IDs. */
object WidgetInstancesSerializer : Serializer<Map<Int, String>> {
    override val defaultValue: Map<Int, String> = emptyMap()

    override suspend fun readFrom(input: InputStream): Map<Int, String> {
        val bytes = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (bytes.size() + count > 32768) throw CorruptionException("Widget selections exceed bound")
            bytes.write(buffer, 0, count)
        }
        try {
            val data = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
            require(data.readInt() == 1)
            val count = data.readInt().also { require(it in 0..100) }
            val result = mutableMapOf<Int, String>()
            repeat(count) {
                val id = data.readInt().also { require(it > 0 && it !in result) }
                result[id] = data.readUTF().also { require(validConnectionId(it)) }
            }
            require(data.read() == -1)
            return result.toMap()
        } catch (error: IOException) {
            throw CorruptionException("Invalid widget selections", error)
        } catch (error: IllegalArgumentException) {
            throw CorruptionException("Unsupported widget selections", error)
        }
    }

    override suspend fun writeTo(t: Map<Int, String>, output: OutputStream) {
        require(t.size <= 100 && t.all { (id, connection) -> id > 0 && validConnectionId(connection) })
        val data = DataOutputStream(output)
        data.writeInt(1)
        data.writeInt(t.size)
        for ((id, connection) in t.toSortedMap()) {
            data.writeInt(id)
            data.writeUTF(connection)
        }
    }
}
