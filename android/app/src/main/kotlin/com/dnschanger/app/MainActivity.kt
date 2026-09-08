package com.dnschanger.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.dnschanger.app/vpn"
    private val vpnController = VpnController()

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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VpnController.VPN_REQUEST_CODE) {
            vpnController.onActivityResult(resultCode == RESULT_OK)
        }
    }
}
