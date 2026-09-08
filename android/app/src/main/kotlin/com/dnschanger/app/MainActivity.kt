package com.dnschanger.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.dnschanger.app/vpn"
    private val vpnController = VpnController()
    private val notificationPermissionCode = 101

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val addresses = (call.argument<List<String>>("addresses") ?: emptyList())
                            .filter { it.isNotBlank() }
                        val port = (call.argument<Number>("port")?.toInt()) ?: 53
                        val allowedPackages = (call.argument<List<String>>("allowedPackages") ?: emptyList())
                            .filter { it.isNotBlank() }

                        // Android 13+: ask for the notification permission so the
                        // persistent "connected" notification is visible. This is
                        // best-effort and does not block starting the VPN.
                        requestNotificationPermission()

                        val permissionIntent = VpnController.prepare(this)
                        if (permissionIntent != null) {
                            vpnController.storePending(this, addresses, port, allowedPackages)
                            startActivityForResult(permissionIntent, VpnController.VPN_REQUEST_CODE)
                            result.success(false)
                        } else {
                            val started = vpnController.start(this, addresses, port, allowedPackages)
                            result.success(started)
                        }
                    }
                    "stop" -> {
                        vpnController.stop(this)
                        result.success(true)
                    }
                    "isRunning" -> result.success(vpnController.isRunning)
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    notificationPermissionCode
                )
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VpnController.VPN_REQUEST_CODE) {
            vpnController.onActivityResult(resultCode == RESULT_OK)
        }
    }
}
