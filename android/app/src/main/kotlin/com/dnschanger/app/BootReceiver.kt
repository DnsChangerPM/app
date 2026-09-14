package com.dnschanger.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Exported so BOOT_COMPLETED is delivered; ignore unrelated explicit
        // QUICKBOOT intents unless the user opted in and VPN consent is already granted.
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON") return

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val autoBoot = prefs.getBoolean("flutter.dns_auto_connect_boot", false)
        if (!autoBoot) return

        if (VpnService.prepare(context) != null) return

        val vpnIntent = Intent(context, DnsVpnService::class.java).apply {
            action = DnsVpnService.ACTION_START
            putExtra(DnsVpnService.EXTRA_START_TICKET, VpnRuntime.nextStartTicket())
            applyLastConfig(context, this)
        }
        try {
            ContextCompat.startForegroundService(context, vpnIntent)
        } catch (_: Exception) {}
    }
}
