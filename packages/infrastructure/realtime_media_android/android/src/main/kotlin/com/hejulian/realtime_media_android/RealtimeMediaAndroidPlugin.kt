package com.hejulian.realtime_media_android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry

/** Android platform-channel owner for native screen media resources. */
class RealtimeMediaAndroidPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {
    companion object {
        private const val CHANNEL_NAME = "ssh_mobile/realtime_media/android"
        private const val PROJECTION_REQUEST_CODE = 41_742
        private const val MAX_ID_LENGTH = 128
    }

    private var context: Context? = null
    private var textureRegistry: TextureRegistry? = null
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var projectionManager: MediaProjectionManager? = null
    private var projectionLease: ProjectionLease? = null
    private var pendingProjectionResult: MethodChannel.Result? = null
    private val owners = HashMap<Long, AndroidMediaOwner>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textureRegistry = binding.textureRegistry
        projectionManager = binding.applicationContext.getSystemService(
            MediaProjectionManager::class.java,
        )
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        disposeOwners()
        channel?.setMethodCallHandler(null)
        channel = null
        textureRegistry = null
        projectionManager = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivityListener()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivityListener()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PROJECTION_REQUEST_CODE) return false
        val pending = pendingProjectionResult ?: return true
        pendingProjectionResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.error("permission_denied", "MediaProjection permission was denied.", null)
            return true
        }
        val appContext = context
        val manager = projectionManager
        if (appContext == null || manager == null) {
            pending.error("backend_failure", "Android projection manager is unavailable.", null)
            return true
        }
        try {
            val mediaProjection = manager.getMediaProjection(resultCode, data)
            if (mediaProjection == null) {
                pending.error("permission_denied", "MediaProjection grant is unavailable.", null)
                return true
            }
            lateinit var lease: ProjectionLease
            val callback = object : MediaProjection.Callback() {
                override fun onStop() {
                    lease.revoke()
                }
            }
            lease = ProjectionLease(
                mediaProjection = mediaProjection,
                callback = callback,
                onRevoked = { ownerToken -> revokeProjection(lease, ownerToken) },
                onReleased = {
                    if (projectionLease === lease) projectionLease = null
                },
            )
            projectionLease = lease
            mediaProjection.registerCallback(callback, Handler(Looper.getMainLooper()))
            pending.success(null)
        } catch (_: SecurityException) {
            projectionLease?.releaseAfterResources()
            pending.error("permission_denied", "MediaProjection permission was rejected.", null)
        } catch (_: Exception) {
            projectionLease?.releaseAfterResources()
            pending.error("backend_failure", "MediaProjection could not be initialized.", null)
        }
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestProjection" -> requestProjection(result)
            "abandonProjectionGrant" -> abandonProjectionGrant(result)
            "listSources" -> result.success(listSources())
            "startCapture" -> handleStartCapture(call, result)
            "attachRemoteVideoSurface" -> withOwner(call, result) { owner, _ ->
                val failure = owner.attachDecoder()
                if (failure != null) {
                    error(result, failure, "Android H.264 decoder could not start.")
                    return@withOwner
                }
                val surfaceId = owner.surfaceId()
                if (surfaceId == null) {
                    error(result, "backend_failure", "Android renderer returned no surface ID.")
                } else {
                    result.success(mapOf("surface_id" to surfaceId))
                }
            }
            "detach" -> withOwner(call, result) { owner, _ ->
                val failure = owner.detach()
                if (failure == null) {
                    stopForegroundServiceIfUnused()
                    result.success(null)
                } else {
                    error(result, failure, "Android media detach failed.")
                }
            }
            "release" -> releaseOwner(call, result)
            "readStats" -> withOwner(call, result) { owner, _ ->
                val terminal = owner.terminalFailure()
                if (terminal != null) {
                    error(result, terminal.first, terminal.second)
                } else {
                    val snapshot = owner.stats()
                    if (snapshot.failure != null) {
                        error(result, snapshot.failure, "Android media statistics are unavailable.")
                    } else {
                        result.success(snapshot.values)
                    }
                }
            }
            "requestKeyframe" -> withOwner(call, result) { owner, _ ->
                val failure = owner.requestKeyframe()
                if (failure == null) result.success(null) else error(
                    result,
                    failure,
                    "Android keyframe recovery failed.",
                )
            }
            "resetDecoder" -> withOwner(call, result) { owner, _ ->
                val failure = owner.resetDecoder()
                if (failure == null) result.success(null) else error(
                    result,
                    failure,
                    "Android decoder reset failed.",
                )
            }
            "applyAdaptation" -> withOwner(call, result) { owner, args ->
                val bitrate = boundedNonNegativeInt(args["bitrate_kbps"])
                val framerate = boundedNonNegativeInt(args["framerate"])
                val width = boundedNonNegativeInt(args["width"])
                val height = boundedNonNegativeInt(args["height"])
                val reason = when (args["reason"] as? String) {
                    "steady" -> 0
                    "congestion" -> 1
                    "recovery" -> 2
                    else -> null
                }
                if (bitrate == null || framerate == null || width == null ||
                    height == null || reason == null
                ) {
                    error(result, "invalid_argument", "A bounded adaptation target is required.")
                    return@withOwner
                }
                val failure = owner.applyAdaptation(
                    bitrate,
                    framerate,
                    width,
                    height,
                    reason,
                )
                if (failure == null) result.success(null) else error(
                    result,
                    failure,
                    "Android hardware encoder rejected the adaptation target.",
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun requestProjection(result: MethodChannel.Result) {
        if (projectionLease != null) {
            error(
                result,
                "duplicate_endpoint",
                "The existing MediaProjection grant is single-use; request a new grant after release.",
            )
            return
        }
        if (pendingProjectionResult != null) {
            error(result, "duplicate_endpoint", "A projection request is already pending.")
            return
        }
        val currentActivity = activity
        val manager = projectionManager
        if (currentActivity == null || manager == null) {
            error(result, "backend_failure", "An attached Android Activity is required.")
            return
        }
        pendingProjectionResult = result
        try {
            currentActivity.startActivityForResult(
                manager.createScreenCaptureIntent(),
                PROJECTION_REQUEST_CODE,
            )
        } catch (_: Exception) {
            pendingProjectionResult = null
            error(result, "backend_failure", "MediaProjection request could not open.")
        }
    }

    private fun abandonProjectionGrant(result: MethodChannel.Result) {
        projectionLease?.releaseIfGranted()
        stopForegroundServiceIfUnused()
        result.success(null)
    }

    /** Wraps the whole owner lookup so pre-block failures release this grant. */
    private fun handleStartCapture(call: MethodCall, result: MethodChannel.Result) {
        val capturedLease = projectionLease
        try {
            withOwner(call, result) { owner, args ->
                val sourceId = args["source_id"] as? String
                val sourceKind = args["source_kind"] as? String
                if (sourceId.isNullOrBlank() || sourceKind.isNullOrBlank()) {
                    error(result, "invalid_argument", "A source ID is required.")
                    return@withOwner
                }
                val appContext = context
                if (appContext == null) {
                    error(result, "backend_failure", "Android capture service context is unavailable.")
                    return@withOwner
                }
                val needsForegroundService = owners.values.none {
                    it.isCaptureOwnerActive()
                }
                if (needsForegroundService) {
                    try {
                        // MediaProjection capture must have its typed foreground
                        // service active before createVirtualDisplay is called.
                        ScreenCaptureForegroundService.start(appContext)
                    } catch (_: SecurityException) {
                        stopForegroundServiceIfUnused()
                        error(
                            result,
                            "permission_denied",
                            "Android capture foreground service permission was rejected.",
                        )
                        return@withOwner
                    } catch (_: Exception) {
                        stopForegroundServiceIfUnused()
                        error(
                            result,
                            "backend_failure",
                            "Android capture foreground service could not start.",
                        )
                        return@withOwner
                    }
                }
                val failure = try {
                    owner.startCapture(projectionLease, sourceId, sourceKind)
                } catch (_: Exception) {
                    "backend_failure"
                }
                if (failure == null) {
                    result.success(null)
                } else {
                    // A failed first capture must compensate the service
                    // request, while another active capture owner keeps it.
                    if (needsForegroundService) stopForegroundServiceIfUnused()
                    error(result, failure, "Android capture could not start.")
                }
            }
        } finally {
            releaseCapturedGrantIfStillCurrent(capturedLease)
        }
    }

    private fun releaseCapturedGrantIfStillCurrent(capturedLease: ProjectionLease?) {
        val released = capturedLease?.let { lease ->
            compensateCapturedProjectionGrant(
                capturedLease = lease,
                currentLease = projectionLease,
                capturedState = lease.state,
                releaseIfGranted = lease::releaseIfGranted,
            )
        } ?: false
        if (released) {
            stopForegroundServiceIfUnused()
        }
    }

    private fun listSources(): List<Map<String, Any>> {
        val appContext = context ?: return emptyList()
        val metrics = appContext.resources.displayMetrics
        return listOf(
            mapOf(
                "id" to "display:default",
                "kind" to "display",
                "label" to "Android display",
                "width" to metrics.widthPixels,
                "height" to metrics.heightPixels,
            ),
        )
    }

    private fun releaseOwner(call: MethodCall, result: MethodChannel.Result) {
        val args = arguments(call)
        val token = ownerToken(args)
        if (token == null) {
            error(result, "invalid_argument", "A native owner token is required.")
            return
        }
        val owner = owners[token]
        val failure = owner?.release()
            ?: if (NativeMediaBridge.closeOwner(token) == 0) null else "backend_failure"
        if (failure == null) {
            if (owner != null) owners.remove(token)
            stopForegroundServiceIfUnused()
            result.success(null)
        } else {
            // Keep a failed owner in the map so a caller can retry cleanup.
            error(result, failure, "Android media owner release failed.")
        }
    }

    private fun withOwner(
        call: MethodCall,
        result: MethodChannel.Result,
        block: (AndroidMediaOwner, Map<String, Any?>) -> Unit,
    ) {
        val args = arguments(call)
        val token = ownerToken(args)
        val identity = parseIdentity(args)
        if (token == null || identity == null) {
            error(result, "invalid_argument", "A complete media owner identity is required.")
            return
        }
        val nativeStatus = NativeMediaBridge.validateOwner(token)
        if (nativeStatus != 0) {
            error(result, statusCode(nativeStatus), "The Android media owner is stale or unavailable.")
            return
        }
        val current = owners[token]
        if (current != null && current.identity != identity) {
            error(result, "stale_endpoint", "The Android owner identity does not match.")
            return
        }
        val owner = current ?: run {
            val registry = textureRegistry
            val appContext = context
            if (registry == null || appContext == null) {
                error(result, "backend_failure", "Android texture registry is unavailable.")
                return
            }
            AndroidMediaOwner(appContext, registry, token, identity).also { owners[token] = it }
        }
        block(owner, args)
    }

    private fun arguments(call: MethodCall): Map<String, Any?> =
        (call.arguments as? Map<*, *>)?.entries?.associate { (key, value) ->
            key.toString() to value
        } ?: emptyMap()

    private fun ownerToken(args: Map<String, Any?>): Long? {
        val value = args["owner_token"] as? String ?: return null
        val token = value.toLongOrNull() ?: return null
        return token.takeIf { it > 0 }
    }

    private fun parseIdentity(args: Map<String, Any?>): AndroidOwnerIdentity? {
        val endpointId = boundedString(args["endpoint_id"]) ?: return null
        val realtimeId = boundedString(args["realtime_id"]) ?: return null
        val peerId = boundedString(args["peer_id"]) ?: return null
        val generation = (args["generation"] as? Number)?.toLong() ?: return null
        val direction = boundedString(args["direction"]) ?: return null
        if (generation <= 0 || direction !in setOf("send", "receive")) return null
        return AndroidOwnerIdentity(endpointId, realtimeId, peerId, generation, direction)
    }

    private fun boundedString(value: Any?): String? {
        val normalized = (value as? String)?.trim() ?: return null
        return normalized.takeIf { it.isNotEmpty() && it.length <= MAX_ID_LENGTH }
    }

    private fun boundedNonNegativeInt(value: Any?): Int? {
        val number = value as? Number ?: return null
        val normalized = number.toDouble()
        if (!normalized.isFinite() || normalized < 0.0 ||
            normalized > Int.MAX_VALUE || normalized % 1.0 != 0.0
        ) {
            return null
        }
        return normalized.toInt()
    }

    private fun revokeProjection(lease: ProjectionLease, ownerToken: Long?) {
        if (projectionLease !== lease) return
        val owner = ownerToken?.let { owners[it] }
        if (owner != null) {
            owner.onProjectionRevoked()
        } else {
            // A grant revoked before it was consumed has no owner to notify;
            // release it immediately so the next request gets a fresh grant.
            lease.releaseAfterResources()
        }
        stopForegroundServiceIfUnused()
    }

    private fun stopForegroundServiceIfUnused() {
        if (owners.values.none { it.isCaptureOwnerActive() }) {
            context?.let { ScreenCaptureForegroundService.stop(it) }
        }
    }

    private fun disposeOwners() {
        pendingProjectionResult?.error("backend_failure", "Android media plugin detached.", null)
        pendingProjectionResult = null
        owners.toList().forEach { (token, owner) ->
            if (owner.release() == null) owners.remove(token)
        }
        projectionLease?.let { lease ->
            if (lease.state != ProjectionLeaseState.CONSUMED) {
                lease.releaseAfterResources()
            }
        }
        stopForegroundServiceIfUnused()
    }

    private fun detachActivityListener() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    private fun error(result: MethodChannel.Result, code: String, message: String) {
        result.error(code, message, null)
    }

    private fun statusCode(status: Int): String = when (status) {
        -1 -> "invalid_argument"
        -2 -> "unknown_session"
        -3 -> "backend_failure"
        -4 -> "session_released"
        -5 -> "stale_generation"
        -6 -> "stale_endpoint"
        -7 -> "direction_mismatch"
        -8 -> "duplicate_endpoint"
        -9 -> "driver_unavailable"
        -10 -> "peer_mismatch"
        -11 -> "frame_rejected"
        -12 -> "stale_owner"
        else -> "backend_failure"
    }
}
