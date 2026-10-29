package com.hejulian.android_server_widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.ComponentCallbacks
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.AppWidgetId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** A cached-data reader. It never constructs Flutter, SSH or an App runtime. */
class ServerMonitorWidget : GlanceAppWidget() {
    // These are fitting bounds, not assumptions about a vendor's launcher grid.
    // Both forms have taller variants so larger cells can honor larger text.
    override val sizeMode = SizeMode.Responsive(setOf(
        DpSize(130.dp, 130.dp), DpSize(150.dp, 150.dp), DpSize(180.dp, 180.dp),
        DpSize(240.dp, 130.dp), DpSize(240.dp, 150.dp), DpSize(240.dp, 180.dp),
        DpSize(280.dp, 130.dp), DpSize(280.dp, 150.dp), DpSize(280.dp, 180.dp),
    ))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val widgetId = (id as? AppWidgetId)?.appWidgetId ?: AppWidgetManager.INVALID_APPWIDGET_ID
        val repository = MonitorSnapshotStorage.repository(context)
        val instances = MonitorSnapshotStorage.instances(context)
        val states = combine(repository.observeState(), instances.observeMappings()) { cache, bindings ->
            val connectionId = bindings[widgetId]
            val server = cache.servers.firstOrNull { it.connectionId == connectionId }
            val sample = connectionId?.let { cache.snapshots[it] }
            WidgetObservation(connectionId, server, sample)
        }.distinctUntilChanged().limitWidgetRefresh(widgetId).map { observation ->
            WidgetStateMapper.map(observation.connectionId, observation.server, observation.snapshot, System.currentTimeMillis())
        }.distinctUntilChanged()
        val initial = states.first()
        // An update wakes an inactive Glance worker, but does not restart a live
        // composition. Observe this instance's derived state until Glance ends
        // the composition; unrelated server writes cannot recompose this UI.
        provideContent { ConfigurationAwareContent(states.collectAsState(initial).value, widgetId) }
    }

    override suspend fun onDelete(context: Context, glanceId: GlanceId) {
        val widgetId = (glanceId as? AppWidgetId)?.appWidgetId ?: return
        MonitorSnapshotStorage.instances(context).removeWidgets(setOf(widgetId))
    }
}

@Composable
private fun ConfigurationAwareContent(state: WidgetDisplayState, widgetId: Int) {
    val application = LocalContext.current.applicationContext
    val configuration = remember(application) {
        mutableStateOf(Configuration(application.resources.configuration))
    }
    DisposableEffect(application) {
        val callback = object : ComponentCallbacks {
            override fun onConfigurationChanged(next: Configuration) {
                configuration.value = Configuration(next)
            }
            override fun onLowMemory() = Unit
        }
        application.registerComponentCallbacks(callback)
        // Close the read/register race without a timer or a process-global
        // observer. Glance releases this callback with its composition.
        configuration.value = Configuration(application.resources.configuration)
        onDispose { application.unregisterComponentCallbacks(callback) }
    }
    val context = remember(configuration.value) {
        application.createConfigurationContext(configuration.value)
    }
    // Responsive Glance keeps all size variants alive. Configuration is mutable
    // outside Compose, so a font/night change must invalidate their text styles.
    CompositionLocalProvider(LocalContext provides context) { WidgetContent(state, widgetId) }
}

@Composable
private fun WidgetContent(state: WidgetDisplayState, widgetId: Int) {
    val context = LocalContext.current
    val wide = LocalSize.current.width >= 240.dp
    val target = Intent(context, WidgetLaunchActivity::class.java)
        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
    Column(
        GlanceModifier.fillMaxSize().appWidgetBackground().background(ImageProvider(R.drawable.server_widget_surface))
            .clickable(actionStartActivity(target)).padding(
                horizontal = if (wide) 12.dp else 8.dp,
                vertical = if (wide) 8.dp else 6.dp,
            ),
    ) {
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(state.displayName, GlanceModifier.defaultWeight(), style(12f, R.color.server_widget_text, true), maxLines = 1)
            if (wide) {
                Spacer(GlanceModifier.width(8.dp))
                Text(context.getString(statusResource(state.status)), style = style(10f, statusColor(state.status)), maxLines = 1)
            }
        }
        Spacer(GlanceModifier.height(if (wide) 4.dp else 3.dp))
        if (wide) ExpandedMetrics(state) else CompactMetrics(state)
        Spacer(GlanceModifier.defaultWeight())
        if (!wide) Text(context.getString(statusResource(state.status)), style = style(8f, statusColor(state.status)), maxLines = 1)
        Text(
            context.getString(R.string.server_widget_sampled, if (wide) state.sampledAt else state.compactSampledAt),
            style = style(if (wide) 9f else 8f, R.color.server_widget_muted), maxLines = 1,
        )
    }
}

@Composable
private fun CompactMetrics(state: WidgetDisplayState) {
    Row(GlanceModifier.fillMaxWidth()) {
        Column(GlanceModifier.defaultWeight()) {
            MetricCell(R.string.server_widget_cpu, state.cpu, R.color.server_widget_blue, 15f)
        }
        Spacer(GlanceModifier.width(8.dp))
        Column(GlanceModifier.defaultWeight()) {
            MetricCell(R.string.server_widget_memory_short, state.memory, R.color.server_widget_cyan, 15f)
        }
    }
    Spacer(GlanceModifier.height(3.dp))
    Row(GlanceModifier.fillMaxWidth()) {
        Column(GlanceModifier.defaultWeight()) {
            MetricCell(R.string.server_widget_network_short, state.network, R.color.server_widget_text, rateTextSize(state.network))
        }
        Spacer(GlanceModifier.width(8.dp))
        Column(GlanceModifier.defaultWeight()) {
            MetricCell(R.string.server_widget_disk_short, state.disk, R.color.server_widget_text, rateTextSize(state.disk))
        }
    }
}

@Composable
private fun MetricCell(label: Int, value: String, color: Int, valueSize: Float) {
    Text(LocalContext.current.getString(label), style = style(8f, R.color.server_widget_muted), maxLines = 1)
    Text(value, style = style(valueSize, color, true), maxLines = 1)
}

private fun rateTextSize(value: String, base: Float = 9.5f) = base * (9f / value.length.coerceAtLeast(1)).coerceAtMost(1f)

@Composable
private fun ExpandedMetrics(state: WidgetDisplayState) {
    Row(GlanceModifier.fillMaxWidth()) {
        Column(GlanceModifier.defaultWeight()) {
            Gauge(R.string.server_widget_cpu, state.cpu, state.cpuProgress, R.color.server_widget_blue)
        }
        Spacer(GlanceModifier.width(16.dp))
        Column(GlanceModifier.defaultWeight()) {
            Gauge(R.string.server_widget_memory, state.memory, state.memoryProgress, R.color.server_widget_cyan)
        }
    }
    Spacer(GlanceModifier.height(5.dp))
    Row(GlanceModifier.fillMaxWidth()) {
        Column(GlanceModifier.defaultWeight()) {
            Text(LocalContext.current.getString(R.string.server_widget_network), style = style(10f, R.color.server_widget_muted), maxLines = 1)
            Text(state.network, style = style(rateTextSize(state.network, 13f), R.color.server_widget_text, true), maxLines = 1)
        }
        Spacer(GlanceModifier.width(16.dp))
        Column(GlanceModifier.defaultWeight()) {
            Text(LocalContext.current.getString(R.string.server_widget_disk), style = style(10f, R.color.server_widget_muted), maxLines = 1)
            Text(state.disk, style = style(rateTextSize(state.disk, 13f), R.color.server_widget_text, true), maxLines = 1)
        }
    }
}

@Composable
private fun Gauge(label: Int, value: String, progress: Float?, color: Int) {
    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(LocalContext.current.getString(label), GlanceModifier.defaultWeight(), style(11f, R.color.server_widget_muted), maxLines = 1)
        Text(value, style = style(16f, color, true), maxLines = 1)
    }
    Spacer(GlanceModifier.height(3.dp))
    LinearProgressIndicator(
        progress = progress ?: 0f, modifier = GlanceModifier.fillMaxWidth().height(3.dp),
        color = ColorProvider(if (progress == null) R.color.server_widget_track else color),
        backgroundColor = ColorProvider(R.color.server_widget_track),
    )
}

@Composable
private fun style(size: Float, color: Int, bold: Boolean = false): TextStyle {
    // Preserve the user's scale within this form's actual line/column budget.
    // Larger responsive bounds increase that budget; no app-wide font override.
    val dimensions = LocalSize.current
    val wide = dimensions.width >= 240.dp
    val fontScale = LocalContext.current.resources.configuration.fontScale.coerceAtLeast(1f)
    val heightBudget = (dimensions.height.value - if (wide) 46f else 28f) / if (wide) 78f else 90f
    val widthBudget = if (wide) (dimensions.width.value - 40f) / 150f else (dimensions.width.value - 24f) / 86f
    val fit = (minOf(heightBudget, widthBudget).coerceIn(0.8f, 2f) / fontScale).coerceAtMost(1f)
    return TextStyle(color = ColorProvider(color), fontSize = (size * fit).sp,
        fontWeight = if (bold) FontWeight.Bold else FontWeight.Normal)
}

private fun statusResource(status: WidgetStatus): Int = when (status) {
    WidgetStatus.notConfigured -> R.string.server_widget_status_not_configured
    WidgetStatus.notStarted -> R.string.server_widget_status_not_started
    WidgetStatus.waiting -> R.string.server_widget_status_waiting
    WidgetStatus.active -> R.string.server_widget_status_active
    WidgetStatus.stopped -> R.string.server_widget_status_stopped
    WidgetStatus.failed -> R.string.server_widget_status_failed
    WidgetStatus.stale -> R.string.server_widget_status_stale
    WidgetStatus.removed -> R.string.server_widget_status_removed
}

private fun statusColor(status: WidgetStatus): Int = when (status) {
    WidgetStatus.active -> R.color.server_widget_cyan
    WidgetStatus.failed, WidgetStatus.stale, WidgetStatus.removed -> R.color.server_widget_warning
    else -> R.color.server_widget_muted
}
