package com.hejulian.android_server_widgets

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Engine-scoped channel only. The application-private DataStore outlives it. */
class AndroidServerWidgetsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.NewIntentListener {
    private var channel: MethodChannel? = null
    private var scope: CoroutineScope? = null
    private var repository: MonitorSnapshotRepository? = null
    private var applicationContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val navigation = WidgetNavigationInbox()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        repository = MonitorSnapshotStorage.repository(binding.applicationContext)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        channel = MethodChannel(binding.binaryMessenger, "ssh_mobile/android_server_widgets").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = scope ?: return result.error("unavailable", "Widget storage detached", null)
        val storage = repository ?: return result.error("unavailable", "Widget storage detached", null)
        owner.launch {
            try {
                when (call.method) {
                    "takePendingNavigation" -> result.success(navigation.take())
                    "beginSession" -> {
                        val session = storage.beginSession()
                        applicationContext?.let { context ->
                            WidgetUpdateDispatcher.refreshChanged(context, storage.servers().map { it.connectionId }.toSet(), true)
                        }
                        result.success(session)
                    }
                    "synchronize" -> {
                        val write = WidgetWrite.fromMap(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                        val previousIds = storage.servers().map { it.connectionId }.toSet()
                        if (storage.synchronize(write)) {
                            applicationContext?.let { context ->
                                if (write.reset) WidgetUpdateDispatcher.resetConfigurations(context)
                                WidgetUpdateDispatcher.refreshChanged(context, previousIds + write.servers.map { it.connectionId })
                            }
                        }
                        result.success(null)
                    }
                    "readSnapshot" -> result.success(storage.snapshotFor(call.argument<String>("connectionId") ?: "")?.toMap())
                    else -> result.notImplemented()
                }
            } catch (_: CancellationException) {
                result.error("unavailable", "Widget storage detached", null)
            } catch (_: IllegalArgumentException) {
                result.error("invalid_snapshot", "Invalid widget snapshot", null)
            } catch (_: Exception) {
                // Never expose storage paths, channel arguments or exception details.
                result.error("storage_unavailable", "Widget storage unavailable", null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        channel?.setMethodCallHandler(null)
        channel = null
        scope?.cancel()
        scope = null
        repository = null
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        detachActivity()
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        captureNavigation(binding.activity.intent)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onDetachedFromActivity() = detachActivity()
    override fun onNewIntent(intent: Intent): Boolean = captureNavigation(intent)

    private fun captureNavigation(intent: Intent?): Boolean {
        if (intent?.action != WidgetNavigationInbox.ACTION_OPEN_MONITOR) return false
        val connectionId = intent.getStringExtra(WidgetNavigationInbox.EXTRA_CONNECTION_ID)
        val requestId = intent.getStringExtra(WidgetNavigationInbox.EXTRA_REQUEST_ID)
        if (!navigation.offer(intent.action, connectionId, requestId)) return false
        activityBinding?.activity?.intent = intent
        channel?.invokeMethod("openMonitoring", mapOf(
            WidgetNavigationInbox.EXTRA_CONNECTION_ID to connectionId,
            WidgetNavigationInbox.EXTRA_REQUEST_ID to requestId,
        ))
        return true
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }
}
