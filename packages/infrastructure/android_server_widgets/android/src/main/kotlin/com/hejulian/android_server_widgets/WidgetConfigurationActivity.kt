package com.hejulian.android_server_widgets

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.content.ComponentName
import android.os.Bundle
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import androidx.glance.appwidget.AppWidgetId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Standard launcher configuration using only the native safe server directory. */
class WidgetConfigurationActivity : Activity() {
    private val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var saving = false
    private lateinit var list: ListView
    private lateinit var message: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        val provider = AppWidgetManager.getInstance(this).getAppWidgetInfo(widgetId)?.provider
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID ||
            provider != ComponentName(this, ServerMonitorWidgetReceiver::class.java)) { finish(); return }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(24), dp(24), dp(16))
            fitsSystemWindows = true
        }
        root.addView(TextView(this).apply {
            setText(R.string.server_widget_choose); textSize = 24f
            setTextColor(getColor(R.color.server_widget_text))
        })
        message = TextView(this).apply {
            setText(R.string.server_widget_choose_hint); textSize = 14f
            setPadding(0, dp(12), 0, dp(16))
            setTextColor(getColor(R.color.server_widget_muted))
        }
        root.addView(message)
        list = ListView(this).apply { id = android.R.id.list; dividerHeight = dp(1) }
        root.addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(Button(this).apply {
            id = android.R.id.button2; setText(R.string.server_widget_cancel)
            setOnClickListener { if (!saving) finish() }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52)))
        setContentView(root)
        owner.launch {
            val servers = MonitorSnapshotStorage.repository(this@WidgetConfigurationActivity).servers()
            if (servers.isEmpty()) {
                message.setText(R.string.server_widget_empty)
                list.emptyView = message
                root.addView(Button(this@WidgetConfigurationActivity).apply {
                    id = android.R.id.button1; setText(R.string.server_widget_open)
                    setOnClickListener { packageManager.getLaunchIntentForPackage(packageName)?.let(::startActivity); finish() }
                })
            } else {
                list.adapter = object : ArrayAdapter<WidgetServer>(this@WidgetConfigurationActivity, android.R.layout.simple_list_item_1, servers) {
                    override fun getView(position: Int, convertView: android.view.View?, parent: ViewGroup): android.view.View {
                        return (super.getView(position, convertView, parent) as TextView).apply {
                            val name = servers[position].displayName
                            text = name
                            setTextColor(getColor(R.color.server_widget_text))
                            contentDescription = getString(R.string.server_widget_select_description, name)
                            minHeight = dp(64); maxLines = 2
                        }
                    }
                }
                list.setOnItemClickListener { _, _, position, _ -> save(servers[position].connectionId) }
            }
        }
    }

    private fun save(connectionId: String) {
        if (saving) return
        saving = true; list.isEnabled = false
        owner.launch {
            try {
                val repository = MonitorSnapshotStorage.repository(this@WidgetConfigurationActivity)
                require(repository.servers().any { it.connectionId == connectionId })
                MonitorSnapshotStorage.instances(this@WidgetConfigurationActivity).configure(widgetId, connectionId)
                ServerMonitorWidget().update(this@WidgetConfigurationActivity, AppWidgetId(widgetId))
                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                finish()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                message.setText(R.string.server_widget_save_failed)
                saving = false; list.isEnabled = true
            }
        }
    }

    @Deprecated("Android Activity back callback")
    override fun onBackPressed() { if (!saving) super.onBackPressed() }

    override fun onDestroy() { owner.cancel(); super.onDestroy() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
