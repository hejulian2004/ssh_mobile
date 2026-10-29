package com.hejulian.android_server_widgets

import android.content.Context
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** One application-process DataStore, independent of Flutter Engine/Activity. */
object MonitorSnapshotStorage {
    private var repository: MonitorSnapshotRepository? = null
    private var instances: WidgetInstanceRepository? = null

    @Synchronized
    fun repository(context: Context): MonitorSnapshotRepository {
        return repository ?: MonitorSnapshotRepository(
            DataStoreFactory.create(
                serializer = MonitorStoreSerializer,
                corruptionHandler = ReplaceFileCorruptionHandler { MonitorStore() },
                scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
                produceFile = { File(context.applicationContext.noBackupFilesDir, "server-monitor-snapshots-v1.bin") },
            ),
        ).also { repository = it }
    }

    @Synchronized
    fun instances(context: Context): WidgetInstanceRepository {
        return instances ?: WidgetInstanceRepository(
            DataStoreFactory.create(
                serializer = WidgetInstancesSerializer,
                corruptionHandler = ReplaceFileCorruptionHandler { emptyMap() },
                scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
                produceFile = { File(context.applicationContext.noBackupFilesDir, "server-monitor-widget-instances-v1.bin") },
            ),
        ).also { instances = it }
    }
}
