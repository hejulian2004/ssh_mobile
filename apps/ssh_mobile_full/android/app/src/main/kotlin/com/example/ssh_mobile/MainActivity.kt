package com.example.ssh_mobile

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.AlarmClock
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var windowPresentation: WindowPresentation? = null
    private var pictureInPicture: ScreenSharePictureInPicture? = null
    private var documentAccess: DocumentAccessSession? = null
    private var credentialProtection: CredentialProtectionSession? = null
    private var credentialForeground = false
    private val channelName = "ssh_mobile/power"
    private val systemChannelName = "ssh_mobile/client_system"
    private val lanDiscoveryChannelName = "ssh_mobile/lan_discovery"
    private val nativeMemoryChannelName = "ssh_mobile/native_memory"

    companion object {
        private const val LOCK_TIMEOUT_MS = 60 * 60 * 1000L
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null
        private var multicastLock: WifiManager.MulticastLock? = null
        private var releaseLocksRunnable: Runnable? = null
    }

    override fun onDestroy() {
        credentialProtection?.dispose()
        credentialProtection = null
        documentAccess?.dispose()
        documentAccess = null
        pictureInPicture?.dispose()
        pictureInPicture = null
        windowPresentation?.dispose()
        windowPresentation = null
        releaseMulticastLock()
        releaseLocks()
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        pictureInPicture?.onUserLeaveHint()
        super.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPicture?.onModeChanged(isInPictureInPictureMode)
    }

    override fun finish() {
        if (pictureInPicture?.shouldMoveTaskBack() == true) {
            moveTaskToBack(true)
            return
        }
        super.finish()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pictureInPicture?.dispose()
        pictureInPicture = null
        windowPresentation?.dispose()
        windowPresentation = WindowPresentation(window, flutterEngine.dartExecutor.binaryMessenger)
        pictureInPicture = ScreenSharePictureInPicture(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            windowPresentation!!,
        )
        documentAccess?.dispose()
        documentAccess = DocumentAccessSession(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        credentialProtection?.dispose()
        credentialProtection = CredentialProtectionSession(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            credentialForeground,
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireLocks" -> {
                    acquireLocks()
                    result.success(true)
                }
                "releaseLocks" -> {
                    releaseLocks()
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestBatteryOptimizationExemption" -> {
                    requestBatteryOptimizationExemption()
                    result.success(true)
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, lanDiscoveryChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(true)
                }
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSystemAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    val hour = (args?.get("hour") as? Number)?.toInt()
                    val minute = (args?.get("minute") as? Number)?.toInt()
                    val message = args?.get("message") as? String
                    val skipUi = args?.get("skipUi") as? Boolean ?: false
                    if (hour == null || minute == null || hour !in 0..23 || minute !in 0..59) {
                        result.error("INVALID_ALARM_TIME", "Alarm hour/minute is invalid", null)
                        return@setMethodCallHandler
                    }
                    result.success(setSystemAlarm(hour, minute, message, skipUi))
                }
                "getNetworkInfo" -> {
                    result.success(getNetworkInfo())
                }
                "getBatteryStatus" -> {
                    result.success(getBatteryStatus())
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeMemoryChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMemoryStats" -> result.success(getNativeMemoryStats())
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (documentAccess?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onResume() {
        super.onResume()
        credentialForeground = true
        credentialProtection?.setForeground(true)
        windowPresentation?.refresh()
    }

    override fun onPause() {
        credentialForeground = false
        credentialProtection?.setForeground(false)
        super.onPause()
    }

    override fun onStop() {
        credentialProtection?.setForeground(false)
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) windowPresentation?.refresh()
    }

    private fun getNativeMemoryStats(): Map<String, Any?> {
        val memInfo = Debug.MemoryInfo()
        Debug.getMemoryInfo(memInfo)
        // Android 23+ 通过公开的 summary.* 统计项提供细分内存数据；旧版本只返回公开 PSS 字段。
        val useStats = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
        fun kb(key: String): Long? {
            if (!useStats) return null
            val raw = memInfo.getMemoryStat(key) ?: return null
            return (raw.toLongOrNull() ?: 0L) * 1024L
        }
        val javaHeap = kb("summary.java-heap") ?: memInfo.dalvikPss.toLong() * 1024L
        val nativeHeap = kb("summary.native-heap") ?: memInfo.nativePss.toLong() * 1024L
        val graphics = kb("summary.graphics") ?: 0L
        val code = kb("summary.code") ?: 0L
        val totalPss = kb("summary.total-pss") ?: memInfo.totalPss.toLong() * 1024L
        return mapOf(
            "available" to useStats,
            "javaHeap" to javaHeap,
            "nativeHeap" to nativeHeap,
            "graphics" to graphics,
            "code" to code,
            "totalPss" to totalPss,
        )
    }

    private fun acquireLocks() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wakeLock?.isHeld != true) {
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "ssh_mobile:SshKeepAliveWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire(LOCK_TIMEOUT_MS)
            }
        }

        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (wifiLock?.isHeld != true) {
            wifiLock = wifiManager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "ssh_mobile:SshKeepAliveWifiLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        scheduleLockTimeout()
    }

    private fun releaseLocks() {
        releaseLocksRunnable?.let {
            Handler(Looper.getMainLooper()).removeCallbacks(it)
        }
        releaseLocksRunnable = null

        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        wifiLock = null

        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock(
            "ssh_mobile:LanDiscoveryMulticastLock"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
        multicastLock = null
    }

    private fun scheduleLockTimeout() {
        val handler = Handler(Looper.getMainLooper())
        releaseLocksRunnable?.let { handler.removeCallbacks(it) }
        val runnable = Runnable { releaseLocks() }
        releaseLocksRunnable = runnable
        handler.postDelayed(runnable, LOCK_TIMEOUT_MS)
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBatteryOptimizations()) {
            return
        }

        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }

        try {
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        startActivity(intent)
    }

    private fun setSystemAlarm(hour: Int, minute: Int, message: String?, skipUi: Boolean): Boolean {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_MESSAGE, message ?: "SSH Mobile")
            putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
        }
        val handler = intent.resolveActivity(packageManager) ?: return false
        return try {
            intent.component = handler
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun getNetworkInfo(): Map<String, Any?> {
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val activeNetwork = connectivityManager.activeNetwork
        val capabilities = activeNetwork?.let { connectivityManager.getNetworkCapabilities(it) }
        val transports = mutableListOf<String>()
        if (capabilities != null) {
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) transports.add("wifi")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) transports.add("cellular")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) transports.add("ethernet")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) transports.add("vpn")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) transports.add("bluetooth")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            ) {
                transports.add("wifiAware")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 &&
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_LOWPAN)
            ) {
                transports.add("lowpan")
            }
        }
        val linkProperties = activeNetwork?.let { connectivityManager.getLinkProperties(it) }
        val dnsServers = linkProperties?.dnsServers?.map { it.hostAddress } ?: emptyList()
        val interfaceName = linkProperties?.interfaceName
        val proxy = linkProperties?.httpProxy
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val wifiInfo = try {
            @Suppress("DEPRECATION")
            wifiManager.connectionInfo
        } catch (_: Exception) {
            null
        }
        return mapOf(
            "connected" to (activeNetwork != null && capabilities != null),
            "validated" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ?: false),
            "metered" to connectivityManager.isActiveNetworkMetered,
            "transports" to transports,
            "vpnActive" to transports.contains("vpn"),
            "interfaceName" to interfaceName,
            "dnsServers" to dnsServers,
            "httpProxyHost" to proxy?.host,
            "httpProxyPort" to proxy?.port,
            "wifiEnabled" to wifiManager.isWifiEnabled,
            "wifiSsid" to sanitizeSsid(wifiInfo?.ssid),
            "wifiBssidAvailable" to (!wifiInfo?.bssid.isNullOrBlank() && wifiInfo?.bssid != "02:00:00:00:00:00"),
            "wifiRssi" to wifiInfo?.rssi,
            "wifiLinkSpeedMbps" to wifiInfo?.linkSpeed,
            "note" to "Some Wi-Fi identifiers may be hidden by Android privacy rules unless location permissions are granted."
        )
    }

    private fun getBatteryStatus(): Map<String, Any?> {
        val batteryIntent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) level * 100.0 / scale else null
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val plugged = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "batteryPercent" to percent,
            "status" to when (status) {
                BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
                BatteryManager.BATTERY_STATUS_FULL -> "full"
                BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "notCharging"
                else -> "unknown"
            },
            "plugged" to mapOf(
                "ac" to ((plugged and BatteryManager.BATTERY_PLUGGED_AC) != 0),
                "usb" to ((plugged and BatteryManager.BATTERY_PLUGGED_USB) != 0),
                "wireless" to ((plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS) != 0)
            ),
            "powerSaveMode" to powerManager.isPowerSaveMode,
            "ignoringBatteryOptimizations" to isIgnoringBatteryOptimizations(),
            "thermalStatus" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) thermalStatusName(powerManager.currentThermalStatus) else "unavailable",
            "note" to "Battery and optimization status describe the client device, useful for SSH keep-alive and monitor background sampling diagnostics."
        )
    }

    private fun sanitizeSsid(ssid: String?): String? {
        if (ssid.isNullOrBlank() || ssid == "<unknown ssid>") return null
        return ssid.trim('"')
    }

    private fun thermalStatusName(status: Int): String {
        return when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown"
        }
    }
}
