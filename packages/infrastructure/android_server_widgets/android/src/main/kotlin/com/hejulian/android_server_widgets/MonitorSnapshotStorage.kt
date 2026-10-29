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
}
