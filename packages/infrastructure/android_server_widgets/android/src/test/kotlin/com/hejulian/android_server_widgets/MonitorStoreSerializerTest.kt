package com.hejulian.android_server_widgets

import androidx.datastore.core.CorruptionException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class MonitorStoreSerializerTest {
    @Test fun roundTripStoresOnlyBoundedDirectoryAndLatestSnapshot() = runBlocking {
        val snapshot = MonitorSnapshot("a", "Compute A", 1793275200000, 0.0, 100.0, null, 2048.0, 300000, MonitorStatus.failed)
        val store = MonitorStore("writer-a", 3, listOf(WidgetServer("a", "Compute A"), WidgetServer("b", "Compute B")), mapOf("a" to snapshot))
        val bytes = ByteArrayOutputStream()
        MonitorStoreSerializer.writeTo(store, bytes)
        assertEquals(store, MonitorStoreSerializer.readFrom(ByteArrayInputStream(bytes.toByteArray())))
        assertEquals(MonitorStore(), MonitorStoreSerializer.defaultValue)
    }

    @Test fun malformedUnsupportedAndOversizedFilesFailClosed() = runBlocking {
        val badVersion = ByteArrayOutputStream().apply { DataOutputStream(this).writeInt(99) }.toByteArray()
        for (bytes in listOf(byteArrayOf(1), badVersion, ByteArray(131073))) {
            try { MonitorStoreSerializer.readFrom(ByteArrayInputStream(bytes)); fail("must reject corrupt file") }
            catch (_: CorruptionException) { }
        }
        val huge = MonitorStore(servers = List(101) { WidgetServer("a-$it", "Node") })
        try { MonitorStoreSerializer.writeTo(huge, ByteArrayOutputStream()); fail("must bound writes") }
        catch (_: IllegalArgumentException) { }
    }
}
