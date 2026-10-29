package com.hejulian.android_server_widgets

import androidx.datastore.core.DataStore
import java.io.IOException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** Owns only widget-instance selections. It never changes a snapshot or monitor. */
class WidgetInstanceRepository(private val store: DataStore<Map<Int, String>>) {
    fun observeMappings(): Flow<Map<Int, String>> = store.data.map { it.toMap() }.catch { error ->
        if (error is IOException) emit(emptyMap()) else throw error
    }.distinctUntilChanged()

    suspend fun configure(widgetId: Int, connectionId: String) {
        require(widgetId > 0 && validConnectionId(connectionId))
        store.updateData { current ->
            require(current.size < 100 || widgetId in current)
            current + (widgetId to connectionId)
        }
    }

    suspend fun connectionFor(widgetId: Int): String? = if (widgetId > 0) mappings()[widgetId] else null

    suspend fun mappings(): Map<Int, String> = try {
        store.data.first().toMap()
    } catch (_: IOException) {
        emptyMap()
    }

    suspend fun removeWidgets(widgetIds: Set<Int>) {
        require(widgetIds.size <= 100 && widgetIds.all { it > 0 })
        store.updateData { it - widgetIds }
    }

    suspend fun restore(oldIds: IntArray, newIds: IntArray) {
        require(oldIds.size == newIds.size && oldIds.size <= 100)
        require(oldIds.all { it > 0 } && newIds.all { it > 0 })
        require(oldIds.toSet().size == oldIds.size && newIds.toSet().size == newIds.size)
        store.updateData { current ->
            val untouched = current - oldIds.toSet()
            require(newIds.none { it in untouched })
            val restored = oldIds.zip(newIds.toList()).mapNotNull { (old, new) ->
                current[old]?.let { new to it }
            }.toMap()
            untouched + restored
        }
    }

    suspend fun clear() { store.updateData { emptyMap() } }
}
