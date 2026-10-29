package com.hejulian.android_server_widgets

import androidx.datastore.core.CorruptionException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class WidgetInstancesSerializerTest {
    @Test fun roundTripAndIncompatibleOrUnboundedFiles() = runBlocking {
        val output = ByteArrayOutputStream()
        val mappings = mapOf(12 to "server-a", 13 to "server-a", 14 to "server-b")
        WidgetInstancesSerializer.writeTo(mappings, output)
        assertEquals(mappings, WidgetInstancesSerializer.readFrom(ByteArrayInputStream(output.toByteArray())))
        assertEquals(emptyMap<Int, String>(), WidgetInstancesSerializer.defaultValue)
        val unsupported = ByteArrayOutputStream().apply { DataOutputStream(this).writeInt(2) }.toByteArray()
        for (bytes in listOf(byteArrayOf(1), unsupported, ByteArray(32769))) {
            try { WidgetInstancesSerializer.readFrom(ByteArrayInputStream(bytes)); fail("must reject corrupt input") }
            catch (_: CorruptionException) { }
        }
        try { WidgetInstancesSerializer.writeTo((1..101).associateWith { "a" }, ByteArrayOutputStream()); fail("must bound") }
        catch (_: IllegalArgumentException) { }
    }
}
