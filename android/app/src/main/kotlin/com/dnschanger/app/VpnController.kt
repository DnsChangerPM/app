package com.dnschanger.app

import android.content.Context
import android.content.Intent
import android.net.VpnService

class VpnController {
    companion object {
        const val VPN_REQUEST_CODE = 24
        fun prepare(context: Context): Intent? = VpnService.prepare(context)
    }

    @Volatile
    var isRunning: Boolean = false
        private set

    private var appContext: Context? = null
    private var pendingAddresses: List<String> = emptyList()
    private var pendingPort: Int = 53
    private var pendingAllowed: List<String> = emptyList()

    fun storePending(context: Context, addresses: List<String>, port: Int, allowedPackages: List<String>) {
        appContext = context.applicationContext
        pendingAddresses = addresses
        pendingPort = port
        pendingAllowed = allowedPackages
    }

    fun start(context: Context, addresses: List<String>, port: Int, allowedPackages: List<String>): Boolean {
        appContext = context.applicationContext
        pendingAddresses = addresses
        pendingPort = port
        pendingAllowed = allowedPackages
        return startService()
    }

    fun onActivityResult(granted: Boolean) {
        if (granted) {
            startService()
        } else {
            isRunning = false
        }
    }

    private fun startService(): Boolean {
        val ctx = appContext ?: return false
        val intent = Intent(ctx, DnsVpnService::class.java)
        intent.action = DnsVpnService.ACTION_START
        intent.putStringArrayListExtra(DnsVpnService.EXTRA_ADDRESSES, ArrayList(pendingAddresses))
        intent.putExtra(DnsVpnService.EXTRA_PORT, pendingPort)
        intent.putStringArrayListExtra(DnsVpnService.EXTRA_ALLOWED_PACKAGES, ArrayList(pendingAllowed))
        try {
            ctx.startService(intent)
            return true
        } catch (e: Exception) {
            return false
        }
    }

    fun stop(context: Context) {
        val intent = Intent(context, DnsVpnService::class.java)
        intent.action = DnsVpnService.ACTION_STOP
        try {
            context.startService(intent)
        } catch (_: Exception) {
        }
    }

    fun onServiceState(running: Boolean) {
        isRunning = running
    }
}
