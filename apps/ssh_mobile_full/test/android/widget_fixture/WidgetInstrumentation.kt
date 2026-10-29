package com.example.ssh_mobile.test

import android.app.Activity
import android.app.Instrumentation
import android.app.UiModeManager
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Bundle
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.TextView
import com.hejulian.android_server_widgets.MonitorSnapshot
import com.hejulian.android_server_widgets.MonitorSnapshotStorage
import com.hejulian.android_server_widgets.MonitorStatus
import com.hejulian.android_server_widgets.ServerMonitorWidgetReceiver
import com.hejulian.android_server_widgets.WidgetConfigurationActivity
import com.hejulian.android_server_widgets.WidgetServer
import com.hejulian.android_server_widgets.WidgetUpdateDispatcher
import com.hejulian.android_server_widgets.WidgetNavigationInbox
import java.io.File
import kotlinx.coroutines.runBlocking

/** Deterministic, local-only Widget fixtures. Never starts monitoring or SSH. */
class WidgetInstrumentation : Instrumentation() {
    private var cleanupOnly = false
    private var preserveSystemConfiguration = false
    private var restoreBoundaryOnly = false

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        cleanupOnly = arguments?.getString("cleanupOnly") == "true"
        preserveSystemConfiguration = arguments?.getString("preserveSystemConfiguration") == "true"
        restoreBoundaryOnly = arguments?.getString("restoreBoundaryOnly") == "true"
        start()
    }

    override fun onStart() {
        val results = Bundle()
        try {
            runBlocking {
                when {
                    restoreBoundaryOnly -> {
                        WidgetRestoreBoundaryFixture.verify(this@WidgetInstrumentation)
                        results.putString("restore_exception_boundary", "PASS")
                    }
                    cleanupOnly -> cleanupFixture()
                    else -> verifyWidgets(results)
                }
            }
            val configuration = targetContext.resources.configuration
            results.putString("stream", when {
                restoreBoundaryOnly -> "Widget restore boundary checks passed\n"
                cleanupOnly -> "Widget fixture cleanup passed\n"
                else -> "Widget fixture checks passed (preserveConfiguration=$preserveSystemConfiguration, fontScale=${configuration.fontScale}, night=${configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK})\n"
            })
            finish(Activity.RESULT_OK, results)
        } catch (failure: Throwable) {
            // Report only the fixed assertion text, never platform exception detail.
            val fixtureLine = failure.stackTrace.firstOrNull { it.className == javaClass.name }?.lineNumber
            results.putString("stream", "Widget fixture failed: ${if (failure is AssertionError) failure.message else failure.javaClass.simpleName} at fixture line $fixtureLine\n")
            finish(Activity.RESULT_CANCELED, results)
        }
    }

    override fun runOnMainSync(runner: Runnable) {
        var failure: Throwable? = null
        super.runOnMainSync {
            try { runner.run() } catch (caught: Throwable) { failure = caught }
        }
        failure?.let { throw it }
    }

    /** Explicit recovery after an instrumentation-process crash; never clears
     * arbitrary App data or a real server's directory. */
    private suspend fun cleanupFixture() {
        val repository = MonitorSnapshotStorage.repository(targetContext)
        val instances = MonitorSnapshotStorage.instances(targetContext)
        val allowed = setOf("widget-fixture-a", "widget-fixture-b")
        check(repository.servers().all { it.connectionId in allowed && it.displayName in setOf("Widget Fixture A", "Widget Fixture B") },
            "Recovery refuses any non-fixture server directory")
        val mappings = instances.mappings()
        check(mappings.values.all { it in allowed }, "Recovery refuses any non-fixture widget mapping")
        instances.removeWidgets(mappings.keys)
        val session = repository.beginSession()
        check(repository.synchronize(session, 1, emptyList(), emptyList(), emptyMap(), true),
            "Guarded fixture cleanup owns its write session")
        runOnMainSync { AppWidgetHost(targetContext, 41731).deleteHost() }
        check(repository.servers().isEmpty() && instances.mappings().isEmpty(),
            "Guarded fixture cleanup leaves no synthetic records")
    }

    private suspend fun verifyWidgets(results: Bundle) {
        val app = targetContext
        if (preserveSystemConfiguration) check(app.packageName == "com.example.ssh_mobile.widget_test",
            "Physical fixture requires the isolated test application")
        else check(Build.HARDWARE in setOf("ranchu", "goldfish"),
            "Global display-setting tests are development-emulator only")
        val repository = MonitorSnapshotStorage.repository(app)
        val instances = MonitorSnapshotStorage.instances(app)
        check(repository.servers().isEmpty(), "Requires an empty fixture-only server directory")
        check(instances.mappings().isEmpty(), "Requires an empty fixture-only widget directory")
        val manager = AppWidgetManager.getInstance(app)
        val provider = ComponentName(app, ServerMonitorWidgetReceiver::class.java)
        val info = manager.installedProviders.singleOrNull { it.provider == provider }
            ?: throw AssertionError("SSH Mobile widget provider is discoverable")
        check(info.configure == ComponentName(app, WidgetConfigurationActivity::class.java), "Provider declares configuration Activity")
        results.putString("provider", "PASS")

        uiAutomation.adoptShellPermissionIdentity("android.permission.BIND_APPWIDGET")
        val formerFontScale = Settings.System.getFloat(app.contentResolver, Settings.System.FONT_SCALE, 1f)
        val formerNightMode = app.getSystemService(UiModeManager::class.java).nightMode
        check(preserveSystemConfiguration || formerNightMode in setOf(UiModeManager.MODE_NIGHT_AUTO, UiModeManager.MODE_NIGHT_NO, UiModeManager.MODE_NIGHT_YES),
            "Requires a standard fixture night-mode setting that can be restored")
        val host = AppWidgetHost(app, 41731)
        val ids = mutableListOf<Int>()
        val ownedIds = mutableSetOf<Int>()
        var session: String? = null
        try {
            runOnMainSync { host.startListening() }
            repeat(3) {
                val id = host.allocateAppWidgetId()
                ids.add(id)
                ownedIds.add(id)
                check(manager.bindAppWidgetIdIfAllowed(id, provider), "Fixture host can bind SSH Mobile widget")
            }
            val empty = startActivitySync(Intent(app, WidgetConfigurationActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, ids[2]).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            awaitCondition("Empty directory offers opening existing client") {
                var ready = false
                runOnMainSync { ready = empty.findViewById<Button>(android.R.id.button1) != null }
                ready
            }
            runOnMainSync { empty.findViewById<Button>(android.R.id.button2).performClick() }
            awaitCondition("Empty directory cancellation finishes") { empty.isFinishing }
            check(instances.connectionFor(ids[2]) == null, "Empty directory never configures a server")
            results.putString("empty_catalog", "PASS")
            session = repository.beginSession()
            // Same fixed latest observation for every layout; the old absolute
            // time intentionally exercises cached/stale display without SSH.
            val time = 946684800000L
            val servers = listOf(WidgetServer("widget-fixture-a", "Widget Fixture A"), WidgetServer("widget-fixture-b", "Widget Fixture B"))
            val snapshots = servers.mapIndexed { index, server ->
                MonitorSnapshot(server.connectionId, server.displayName, time, 42.0 + index, 63.0, 1024.0, 2048.0, 10000, MonitorStatus.active)
            }
            repository.synchronize(session, 1, servers, snapshots, emptyMap(), false)
            instances.configure(ids[0], servers[0].connectionId)
            instances.configure(ids[1], servers[1].connectionId)
            val compact = verifyLayout(host, manager, info, ids[0], 150, 150, 1f, false, "compact")
            val displayedAt = System.nanoTime()
            repository.synchronize(session, 2, servers,
                snapshots.map { if (it.connectionId == servers[0].connectionId) it.copy(cpuPercent = 43.0, sampledAt = time + 1000) else it }, emptyMap(), false)
            WidgetUpdateDispatcher.refreshChanged(app, setOf(servers[0].connectionId))
            // Observe the whole ordinary-sample budget, including its expiry:
            // no timer should publish the pending sample without a new event.
            while (System.nanoTime() - displayedAt < 15_200_000_000L) {
                var retained = false
                runOnMainSync { retained = textViews(compact).any { it.text.toString() == "42%" } }
                check(retained, "Active composition retains the displayed sample during its 15-second budget")
                Thread.sleep(50)
            }
            repository.synchronize(session, 3, servers,
                snapshots.map { if (it.connectionId == servers[0].connectionId) it.copy(cpuPercent = 44.0, sampledAt = time + 16000) else it }, emptyMap(), false)
            WidgetUpdateDispatcher.refreshChanged(app, setOf(servers[0].connectionId))
            awaitCondition("An active Glance composition observes a new persisted sample") {
                var fresh = false
                runOnMainSync { fresh = textViews(compact).any { it.text.toString() == "44%" } }
                fresh
            }
            repository.synchronize(session, 4, servers,
                snapshots.map { if (it.connectionId == servers[0].connectionId)
                    it.copy(cpuPercent = 44.0, sampledAt = time + 16001, status = MonitorStatus.failed) else it }, emptyMap(), false)
            WidgetUpdateDispatcher.refreshChanged(app, setOf(servers[0].connectionId), immediate = true)
            awaitCondition("Status changes publish immediately inside the sample budget", timeoutMillis = 5000) {
                var failed = false
                runOnMainSync { failed = textViews(compact).any { it.text.toString() == app.getString(com.hejulian.android_server_widgets.R.string.server_widget_status_failed) } }
                failed
            }
            repository.synchronize(session, 5, servers,
                snapshots.map { if (it.connectionId == servers[0].connectionId) it.copy(sampledAt = time + 16002) else it }, emptyMap(), false)
            WidgetUpdateDispatcher.refreshChanged(app, setOf(servers[0].connectionId), immediate = true)
            awaitCondition("The same Glance composition observes the restored fixture", timeoutMillis = 5000) {
                var fresh = false
                runOnMainSync { fresh = textViews(compact).any { it.text.toString() == "42%" } }
                fresh
            }
            results.putString("active_composition_refresh", "PASS")
            results.putString("active_composition_sample_budget", "PASS")
            verifyLayout(host, manager, info, ids[0], 130, 130, 2f, false, "compact-minimum-large-font")
            verifyLayout(host, manager, info, ids[0], 260, 150, 1.5f, false, "expanded-mid-grid")
            verifyLayout(host, manager, info, ids[0], 320, 150, 1.5f, true, "expanded-large-night")
            check(instances.connectionFor(ids[1]) == servers[1].connectionId, "Independent widget keeps its server")
            results.putString("cached_render_no_flutter", "PASS")
            results.putString(if (preserveSystemConfiguration) "compact_expanded_current_configuration" else "compact_expanded_large_font", "PASS")

            val canceled = startActivitySync(Intent(app, WidgetConfigurationActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, ids[2]).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            runOnMainSync { canceled.findViewById<Button>(android.R.id.button2).performClick() }
            awaitCondition("Cancel finishes configuration") { canceled.isFinishing }
            check(instances.connectionFor(ids[2]) == null, "Cancel does not configure an instance")

            val configured = startActivitySync(Intent(app, WidgetConfigurationActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, ids[2]).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            awaitCondition("Configuration loads safe directory") {
                var ready = false
                runOnMainSync { ready = (configured.findViewById<ListView>(android.R.id.list)?.adapter?.count ?: 0) == 2 }
                ready
            }
            runOnMainSync {
                val list = configured.findViewById<ListView>(android.R.id.list)
                val row = list.adapter.getView(0, null, list) as TextView
                check(row.currentTextColor == configured.getColor(com.hejulian.android_server_widgets.R.color.server_widget_text),
                    "Native configuration row uses readable theme text")
                list.performItemClick(row, 0, list.adapter.getItemId(0))
            }
            awaitCondition("Selection finishes configuration") { configured.isFinishing }
            check(instances.connectionFor(ids[2]) == servers[0].connectionId, "Selection persists appWidgetId to server")
            results.putString("configuration_cancel_select", "PASS")

            val deleted = ids.removeAt(0)
            runOnMainSync { host.deleteAppWidgetId(deleted) }
            // AppWidgetHost asks the system to deliver its protected deletion
            // broadcast. The App must not forge that system-only broadcast.
            awaitCondition("Receiver removes deleted widget mapping") {
                runBlocking { instances.connectionFor(deleted) == null }
            }
            check(instances.connectionFor(ids[0]) == servers[1].connectionId, "Deleting one widget preserves another")
            check(repository.snapshotFor(servers[0].connectionId) != null, "Deleting a widget preserves server data")
            results.putString("multi_instance_delete", "PASS")

            // Done last: cached rendering and configuration above never need a
            // Flutter Activity or Engine. A click now opens the existing client.
            val clickView = verifyLayout(host, manager, info, ids[0], 260, 150, 1f, false, "click-target-b", "43%")
            val visibleHost = startActivitySync(Intent(app, WidgetConfigurationActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, ids[0]).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            runOnMainSync {
                visibleHost.setContentView(FrameLayout(visibleHost).apply {
                    addView(clickView, FrameLayout.LayoutParams(clickView.measuredWidth, clickView.measuredHeight))
                })
            }
            val opened = addMonitor("com.example.ssh_mobile.MainActivity", null, false)
            try {
                runOnMainSync {
                    val target = clickTarget(clickView)
                        ?: throw AssertionError("Glance root has a clickable action")
                    check(target.performClick(), "Glance click dispatches its PendingIntent")
                }
                val main = opened.waitForActivityWithTimeout(20_000)
                    ?: throw AssertionError("Widget click opens the existing Flutter Activity")
                check(main.componentName.className == "com.example.ssh_mobile.MainActivity", "Widget uses existing client Activity")
                check(main.intent.getStringExtra(WidgetNavigationInbox.EXTRA_CONNECTION_ID) == servers[1].connectionId,
                    "Widget click forwards its own configured server only")
                runOnMainSync { main.finish() }
                results.putString("click_existing_activity", "PASS")
            } finally {
                removeMonitor(opened)
                runOnMainSync { visibleHost.finish() }
            }
        } finally {
            if (!preserveSystemConfiguration) {
                shell("settings put system font_scale $formerFontScale")
                shell("cmd uimode night ${when (formerNightMode) { UiModeManager.MODE_NIGHT_AUTO -> "auto"; UiModeManager.MODE_NIGHT_YES -> "yes"; else -> "no" }}")
            }
            instances.removeWidgets(ownedIds)
            runOnMainSync {
                ids.forEach(host::deleteAppWidgetId)
                host.stopListening()
                host.deleteHost()
            }
            // The real Flutter Activity can legitimately replace the native
            // writer session. Re-acquire only after the fixed-fixture guards;
            // never weaken production's rejection of our obsolete token.
            if (session != null) cleanupFixture()
            uiAutomation.dropShellPermissionIdentity()
        }
        results.putString("fixture_cleanup", "PASS")
    }

    private suspend fun verifyLayout(
        host: AppWidgetHost, manager: AppWidgetManager, info: android.appwidget.AppWidgetProviderInfo,
        id: Int, width: Int, height: Int, fontScale: Float, night: Boolean, name: String,
        expectedCpu: String = "42%",
    ): AppWidgetHostView {
        val requestedFontScale = if (preserveSystemConfiguration) targetContext.resources.configuration.fontScale else fontScale
        val requestedNight = if (preserveSystemConfiguration)
            targetContext.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES else night
        val captureName = if (preserveSystemConfiguration) "$name-current-font-$requestedFontScale-night-$requestedNight" else name
        if (!preserveSystemConfiguration) {
            shell("settings put system font_scale $requestedFontScale")
            shell("cmd uimode night ${if (requestedNight) "yes" else "no"}")
        }
        awaitCondition("Device applies fixture font scale") {
            kotlin.math.abs(targetContext.resources.configuration.fontScale - requestedFontScale) < 0.01f
        }
        val options = Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, width)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, width)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, height)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, height)
            putParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, arrayListOf(SizeF(width.toFloat(), height.toFloat())))
        }
        manager.updateAppWidgetOptions(id, options)
        val configuration = Configuration(targetContext.resources.configuration).apply {
            this.fontScale = requestedFontScale
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (requestedNight) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        val context = targetContext.createConfigurationContext(configuration)
        lateinit var view: AppWidgetHostView
        runOnMainSync { view = host.createView(context, id, info) }
        val connectionId = MonitorSnapshotStorage.instances(targetContext).connectionFor(id)
            ?: throw AssertionError("Layout fixture has a configured server")
        WidgetUpdateDispatcher.refreshChanged(targetContext, setOf(connectionId), immediate = true)
        val tokens = listOf(expectedCpu, "63%", "1.0 KiB/s", "2.0 KiB/s")
        val sampledPrefix = context.getString(com.hejulian.android_server_widgets.R.string.server_widget_sampled, "")
        val status = context.getString(com.hejulian.android_server_widgets.R.string.server_widget_status_stale)
        var observed = ""
        var geometry = ""
        try { awaitCondition("All four cached readings render in $name") {
            var rendered = false
            runOnMainSync {
                val density = context.resources.displayMetrics.density
                // Widget options describe content dp. The host may add its
                // framework padding outside that available content rectangle.
                val w = (width * density).toInt() + view.paddingLeft + view.paddingRight
                val h = (height * density).toInt() + view.paddingTop + view.paddingBottom
                view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
                view.layout(0, 0, w, h)
                val labels = textViews(view)
                observed = labels.joinToString(" | ") { it.text.toString() }.take(256)
                val metadata = labels.filter { it.text.toString() == status || it.text.toString().startsWith(sampledPrefix) }
                geometry = (tokens.mapNotNull { token -> labels.firstOrNull { it.text.toString() == token } } + metadata).joinToString("; ") { label ->
                    "${label.text} width=${label.width} height=${label.height} textSize=${label.textSize} fits=${metricFits(label, view)}"
                }
                // Data and configuration redraws are asynchronous. The same
                // text can still be present in an older, incorrectly sized
                // RemoteViews while the replacement is on its way.
                rendered = tokens.all { token -> labels.any { it.text.toString() == token && metricFits(it, view) } } &&
                    labels.any { it.text.toString() == status && metricFits(it, view) } &&
                    labels.any { it.text.toString().startsWith(sampledPrefix) && metricFits(it, view) } &&
                    (width < 240 || progressBars(view) == 2)
            }
            rendered
        } } catch (_: AssertionError) {
            runOnMainSync { capture(view, captureName) }
            // This host only contains this runner's guarded synthetic fixtures.
            throw AssertionError("All four cached readings fit in $name; observed fixture labels: $observed; $geometry")
        }
        runOnMainSync {
            // This deterministic host is not attached to a window. A queued
            // RemoteViews replacement between the await and this turn cannot
            // rely on window traversal to measure its new children.
            val density = context.resources.displayMetrics.density
            val w = (width * density).toInt() + view.paddingLeft + view.paddingRight
            val h = (height * density).toInt() + view.paddingTop + view.paddingBottom
            view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, w, h)
            capture(view, captureName)
            if (width >= 240) check(progressBars(view) == 2, "Expanded layout shows CPU and memory progress bars in $name")
            for (token in tokens) {
                val label = textViews(view).first { it.text.toString() == token }
                val layout = label.layout
                check(layout != null && (0 until layout.lineCount).none { layout.getEllipsisCount(it) > 0 }, "Metric $token text is not clipped in $name (width=${label.width}, textSize=${label.textSize})")
                check(label.width > 0 && label.height > 0, "Metric remains visible in $name")
                val bounds = Rect()
                label.getDrawingRect(bounds)
                view.offsetDescendantRectToMyCoords(label, bounds)
                check(bounds.left >= view.paddingLeft && bounds.top >= view.paddingTop &&
                    bounds.right <= view.width - view.paddingRight && bounds.bottom <= view.height - view.paddingBottom,
                    "Metric fits the host bounds in $name")
                check(layout!!.height + label.totalPaddingTop + label.totalPaddingBottom <= label.height + 1,
                    "Metric text fits its measured height in $name")
            }
            val metadata = textViews(view).filter { it.text.toString() == status || it.text.toString().startsWith(sampledPrefix) }
            check(metadata.size == 2 && metadata.all { metricFits(it, view) }, "Status and absolute sample time remain fully visible in $name")
        }
        return view
    }

    private fun metricFits(label: TextView, host: AppWidgetHostView): Boolean {
        val layout = label.layout ?: return false
        if (label.width <= 0 || label.height <= 0 || label.visibility != View.VISIBLE ||
            (0 until layout.lineCount).any { layout.getEllipsisCount(it) > 0 } ||
            layout.height + label.totalPaddingTop + label.totalPaddingBottom > label.height + 1) return false
        val bounds = Rect()
        label.getDrawingRect(bounds)
        host.offsetDescendantRectToMyCoords(label, bounds)
        if (bounds.left < host.paddingLeft || bounds.top < host.paddingTop ||
            bounds.right > host.width - host.paddingRight || bounds.bottom > host.height - host.paddingBottom) return false
        var ancestor = label.parent
        while (ancestor is ViewGroup) {
            if (ancestor.clipChildren) {
                val visible = Rect()
                label.getDrawingRect(visible)
                ancestor.offsetDescendantRectToMyCoords(label, visible)
                val left = if (ancestor.clipToPadding) ancestor.paddingLeft else 0
                val top = if (ancestor.clipToPadding) ancestor.paddingTop else 0
                val right = ancestor.width - if (ancestor.clipToPadding) ancestor.paddingRight else 0
                val bottom = ancestor.height - if (ancestor.clipToPadding) ancestor.paddingBottom else 0
                if (visible.left < left || visible.top < top || visible.right > right || visible.bottom > bottom) return false
            }
            if (ancestor === host) break
            ancestor = ancestor.parent
        }
        return true
    }

    private fun capture(view: AppWidgetHostView, name: String) {
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        val file = File(targetContext.externalCacheDir, "widget-fixture-$name.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun textViews(view: View): List<TextView> = when (view) {
        is TextView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { textViews(view.getChildAt(it)) }
        else -> emptyList()
    }

    private fun progressBars(view: View): Int = when (view) {
        is ProgressBar -> 1
        is ViewGroup -> (0 until view.childCount).sumOf { progressBars(view.getChildAt(it)) }
        else -> 0
    }

    private fun clickTarget(view: View): View? {
        if (view.isClickable && view.hasOnClickListeners()) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) clickTarget(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun awaitCondition(label: String, timeoutMillis: Long = 20_000, condition: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (!condition()) {
            if (System.nanoTime() >= deadline) throw AssertionError(label)
            Thread.sleep(50)
        }
    }

    private fun shell(command: String) {
        uiAutomation.executeShellCommand(command).use { descriptor ->
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }
        }
    }

    private fun check(value: Boolean, message: String) {
        if (!value) throw AssertionError(message)
    }
}
