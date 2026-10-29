package com.example.ssh_mobile.test

import android.app.Instrumentation
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Intent
import android.os.Build
import com.hejulian.android_server_widgets.MonitorSnapshotStorage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Test-only asynchronous exception probe; never starts SSH or changes stored data. */
object WidgetRestoreBoundaryFixture {
    suspend fun verify(instrumentation: Instrumentation) {
        check(Build.HARDWARE in setOf("ranchu", "goldfish")) { "Restore exception probe is emulator-only" }
        val context = instrumentation.targetContext
        val instances = MonitorSnapshotStorage.instances(context)
        val before = instances.mappings()
        val escaped = AtomicReference<Throwable?>()
        val failureArrived = CountDownLatch(1)
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        // Keep the deliberately failing Red candidate alive long enough to
        // report the assertion and restore the process handler in finally.
        Thread.setDefaultUncaughtExceptionHandler { _, failure ->
            escaped.compareAndSet(null, failure)
            failureArrived.countDown()
        }
        try {
            instrumentation.runOnMainSync {
                // Exercise the real receiver through the Android public base;
                // the App's test compile classpath need not expose Glance.
                val receiver = Class.forName("com.hejulian.android_server_widgets.ServerMonitorWidgetReceiver")
                    .getDeclaredConstructor().newInstance() as BroadcastReceiver
                receiver.onReceive(context,
                    Intent(AppWidgetManager.ACTION_APPWIDGET_RESTORED)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_OLD_IDS, intArrayOf(1))
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf()))
            }
            // onReceive is intentionally fire-and-forget. Observe the actual
            // process-level coroutine failure channel through a bounded window,
            // rather than adding a completion hook to the production receiver.
            failureArrived.await(2, TimeUnit.SECONDS)
            if (escaped.get() != null) throw AssertionError("Invalid restore exception escaped the asynchronous receiver")
            if (instances.mappings() != before) throw AssertionError("Invalid restore changed widget instance bindings")
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previousHandler)
        }
    }
}
