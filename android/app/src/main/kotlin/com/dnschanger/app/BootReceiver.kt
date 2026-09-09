package com.dnschanger.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON") return

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        // Flutter SharedPreferences prefixes keys with "flutter."
        val autoBoot = prefs.getBoolean("flutter.dns_auto_connect_boot", false)
        if (!autoBoot) return

        if (VpnService.prepare(context) != null) return

        val addresses = listOf("1.1.1.1", "1.0.0.1")
        val vpnIntent = Intent(context, DnsVpnService::class.java).apply {
            action = DnsVpnService.ACTION_START
            putExtra(DnsVpnService.EXTRA_START_TICKET, VpnRuntime.nextStartTicket())
            putStringArrayListExtra(DnsVpnService.EXTRA_ADDRESSES, ArrayList(addresses))
            putExtra(DnsVpnService.EXTRA_PORT, 53)
        }
        try {
            ContextCompat.startForegroundService(context, vpnIntent)
        } catch (_: Exception) {}
    }
}
