package com.dnschanger.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var vpnController: VpnController? = null
    private var apkInstaller: ApkInstaller? = null
    private var vpnChannel: MethodChannel? = null
    private var updateChannel: MethodChannel? = null
    private var statusChannel: EventChannel? = null
    private var statusSink: EventChannel.EventSink? = null
    private var statusListener: ((VpnSnapshot) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        vpnController = VpnController(this)
        apkInstaller = ApkInstaller(this)
        vpnChannel = MethodChannel(messenger, VpnController.CHANNEL).also { it.setMethodCallHandler(vpnController) }
        updateChannel = MethodChannel(messenger, ApkInstaller.CHANNEL).also { it.setMethodCallHandler(apkInstaller) }
        statusChannel = EventChannel(messenger, VpnController.EVENTS).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    removeStatusListener()
                    statusSink = events
                    val listener: (VpnSnapshot) -> Unit = { snapshot ->
                        runOnUiThread {
                            statusSink?.success(snapshot.toMap(VpnNotifications.enabled(this@MainActivity)))
                        }
                    }
                    statusListener = listener
                    VpnRuntime.addListener(listener)
                    publishStatus()
                }

                override fun onCancel(arguments: Any?) = removeStatusListener()
            })
        }
    }

    private fun publishStatus() {
        val current = VpnRuntime.snapshot
        // A permission/channel change is a new observation too. Advance its
        // revision so an older getStatus reply cannot restore a stale warning.
        VpnRuntime.publish(current.phase, current.errorCode)
    }

    private fun removeStatusListener() {
        statusListener?.let { VpnRuntime.removeListener(it) }
        statusListener = null
        statusSink = null
    }

    override fun onResume() {
        super.onResume()
        // Notification permissions/channel settings may have changed outside
        // Flutter, even if the tunnel state itself is unchanged.
        publishStatus()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (apkInstaller?.onActivityResult(requestCode, resultCode) == true) return
        vpnController?.onActivityResult(requestCode, resultCode)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        vpnController?.onNotificationPermissionResult(requestCode)
        publishStatus()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        removeStatusListener()
        vpnChannel?.setMethodCallHandler(null)
        updateChannel?.setMethodCallHandler(null)
        statusChannel?.setStreamHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        removeStatusListener()
        vpnController?.dispose()
        vpnController = null
        apkInstaller?.dispose()
        apkInstaller = null
        super.onDestroy()
    }
}
