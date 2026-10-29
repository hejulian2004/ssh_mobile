package com.hejulian.android_server_widgets

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Engine-scoped channel only. The application-private DataStore outlives it. */
class AndroidServerWidgetsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var scope: CoroutineScope? = null
    private var repository: MonitorSnapshotRepository? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
                    "beginSession" -> result.success(storage.beginSession())
                    "synchronize" -> {
                        storage.synchronize(WidgetWrite.fromMap(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()))
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
        channel?.setMethodCallHandler(null)
        channel = null
        scope?.cancel()
        scope = null
        repository = null
    }
}
