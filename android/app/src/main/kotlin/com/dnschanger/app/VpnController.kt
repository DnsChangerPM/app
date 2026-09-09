package com.dnschanger.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Serializes the two Android permission dialogs; command success is only ACK. */
class VpnController(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.dnschanger.app/vpn"
        const val EVENTS = "com.dnschanger.app/vpn_state"
        const val VPN_REQUEST_CODE = 24
        const val NOTIFICATION_PERMISSION_CODE = 101

        fun stopNative(context: Context) {
            VpnRuntime.cancelQueuedStarts()
            val service = Intent(context, DnsVpnService::class.java)
            val previous = VpnRuntime.snapshot
            if (VpnRuntime.serviceAlive) {
                VpnRuntime.publish(VpnPhase.STOPPING)
                try {
                    // Android can keep a VpnService bound while its TUN exists.
                    // stopService alone is not enough: close TUN/notification in
                    // ACTION_STOP first, then let the service call stopSelf.
                    context.startService(service.setAction(DnsVpnService.ACTION_STOP))
                    return
                } catch (_: Exception) {
                    VpnRuntime.publish(previous.phase, "command_failed")
                    throw VpnFailure("command_failed")
                }
            }
            // Cancel a queued start/permission flow without creating a service.
            context.stopService(service)
            VpnRuntime.publish(VpnPhase.DISCONNECTED)
        }
    }

    private data class Request(val config: VpnConfig?, val resume: Boolean)
    private var pending: Request? = null

    fun status(): Map<String, Any?> = VpnRuntime.snapshot.toMap(VpnNotifications.enabled(activity))

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    requirePhase(VpnPhase.DISCONNECTED, VpnPhase.ERROR)
                    val config = VpnConfig.parse(
                        call.argument<List<String>>("addresses") ?: emptyList(),
                        call.argument<Number>("port")?.toInt() ?: 53,
                        call.argument<List<String>>("allowedPackages") ?: emptyList(),
                        call.argument<List<String>>("disallowedPackages") ?: emptyList(),
                        call.argument<Boolean>("enableIpv6") ?: true
                    )
                    if (activity.packageName in config.allowedPackages) throw VpnFailure("invalid_target")
                    begin(Request(config, false))
                    result.success(null)
                }
                "pause" -> {
                    requirePhase(VpnPhase.CONNECTED)
                    VpnRuntime.publish(VpnPhase.PAUSING)
                    try {
                        activity.startService(Intent(activity, DnsVpnService::class.java).setAction(DnsVpnService.ACTION_PAUSE))
                    } catch (_: Exception) {
                        VpnRuntime.publish(VpnPhase.CONNECTED, "command_failed")
                        throw VpnFailure("command_failed")
                    }
                    result.success(null)
                }
                "resume" -> {
                    requirePhase(VpnPhase.PAUSED)
                    begin(Request(null, true))
                    result.success(null)
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "getStatus" -> result.success(status())
                "isRunning" -> result.success(VpnRuntime.snapshot.phase == VpnPhase.CONNECTED)
                "openNotificationSettings" -> {
                    activity.startActivity(VpnNotifications.settingsIntent(activity))
                    result.success(null)
                }
                "getInstalledApps" -> {
                    val pm = activity.packageManager
                    val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
                        addCategory(Intent.CATEGORY_LAUNCHER)
                    }
                    val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pm.queryIntentActivities(mainIntent, PackageManager.ResolveInfoFlags.of(0L))
                    } else {
                        @Suppress("DEPRECATION")
                        pm.queryIntentActivities(mainIntent, 0)
                    }
                    val list = resolved.mapNotNull { resolveInfo ->
                        val pkg = resolveInfo.activityInfo?.packageName ?: return@mapNotNull null
                        if (pkg == activity.packageName) return@mapNotNull null
                        val label = resolveInfo.loadLabel(pm)?.toString() ?: pkg
                        val isSystem = (resolveInfo.activityInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                        mapOf(
                            "packageName" to pkg,
                            "appName" to label,
                            "isSystemApp" to isSystem
                        )
                    }.distinctBy { it["packageName"] }
                    result.success(list)
                }
                "getNetworkInfo" -> {
                    val cm = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val active = cm.activeNetwork
                    val caps = active?.let { cm.getNetworkCapabilities(it) }
                    val type = when {
                        caps == null -> "none"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                        else -> "other"
                    }
                    result.success(mapOf(
                        "type" to type,
                        "isConnected" to (active != null)
                    ))
                }
                else -> result.notImplemented()
            }
        } catch (failure: VpnFailure) {
            result.error(failure.code, "VPN operation could not be completed", null)
        } catch (_: Exception) {
            result.error("command_failed", "VPN operation could not be completed", null)
        }
    }

    private fun requirePhase(vararg phases: VpnPhase) {
        if (VpnRuntime.snapshot.phase != VpnPhase.REQUESTING_PERMISSION) pending = null
        if (pending != null || VpnRuntime.snapshot.phase !in phases) throw VpnFailure("busy")
    }

    private fun begin(request: Request) {
        pending = request
        VpnRuntime.publish(VpnPhase.REQUESTING_PERMISSION)
        val prefs = activity.getSharedPreferences("vpn_permissions", Context.MODE_PRIVATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean("notification_requested", false)) {
            prefs.edit().putBoolean("notification_requested", true).apply()
            try {
                // Never overlap this with VpnService.prepare's permission dialog.
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_CODE)
                return
            } catch (_: Exception) { }
        }
        requestVpnConsent()
    }

    private fun currentRequest(): Request? {
        if (VpnRuntime.snapshot.phase != VpnPhase.REQUESTING_PERMISSION) pending = null
        return pending
    }

    private fun requestVpnConsent() {
        if (currentRequest() == null) return
        try {
            val intent = VpnService.prepare(activity)
            if (intent == null) dispatchPending() else activity.startActivityForResult(intent, VPN_REQUEST_CODE)
        } catch (_: Exception) {
            rejectPending("permission_required")
        }
    }

    fun onNotificationPermissionResult(requestCode: Int): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_CODE) return false
        requestVpnConsent()
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != VPN_REQUEST_CODE) return false
        if (currentRequest() == null) return true
        if (resultCode == Activity.RESULT_OK) dispatchPending() else rejectPending("permission_denied")
        return true
    }

    private fun dispatchPending() {
        val request = currentRequest() ?: return
        pending = null
        VpnRuntime.publish(VpnPhase.CONNECTING)
        val intent = Intent(activity, DnsVpnService::class.java)
            .setAction(if (request.resume) DnsVpnService.ACTION_RESUME else DnsVpnService.ACTION_START)
            .putExtra(DnsVpnService.EXTRA_START_TICKET, VpnRuntime.nextStartTicket())
        request.config?.let { config ->
            intent.putStringArrayListExtra(DnsVpnService.EXTRA_ADDRESSES, ArrayList(config.encodedAddresses))
            intent.putStringArrayListExtra(DnsVpnService.EXTRA_ALLOWED_PACKAGES, ArrayList(config.allowedPackages))
            intent.putStringArrayListExtra(DnsVpnService.EXTRA_DISALLOWED_PACKAGES, ArrayList(config.disallowedPackages))
            intent.putExtra(DnsVpnService.EXTRA_ENABLE_IPV6, config.enableIpv6)
            intent.putExtra(DnsVpnService.EXTRA_PORT, 53)
        }
        try {
            ContextCompat.startForegroundService(activity, intent)
        } catch (_: Exception) {
            VpnRuntime.publish(if (request.resume && VpnRuntime.serviceAlive) VpnPhase.PAUSED else VpnPhase.ERROR, "start_failed")
        }
    }

    private fun rejectPending(code: String) {
        val request = pending ?: return
        pending = null
        VpnRuntime.publish(if (request.resume && VpnRuntime.serviceAlive) VpnPhase.PAUSED else VpnPhase.DISCONNECTED, code)
    }

    fun stop() {
        pending = null
        stopNative(activity)
    }

    fun dispose() {
        if (pending != null && VpnRuntime.snapshot.phase == VpnPhase.REQUESTING_PERMISSION) {
            rejectPending("permission_denied")
        }
        pending = null
    }
}
