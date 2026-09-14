package com.dnschanger.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat

@RequiresApi(Build.VERSION_CODES.N)
class DnsTileService : TileService() {

    companion object {
        @Volatile private var lastActive: Boolean? = null

        fun updateTileState(context: Context, active: Boolean) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                if (lastActive == active) return
                lastActive = active
                try {
                    requestListeningState(context, ComponentName(context, DnsTileService::class.java))
                } catch (_: Exception) {}
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileUI()
    }

    override fun onClick() {
        super.onClick()
        val isConnected = VpnRuntime.snapshot.phase == VpnPhase.CONNECTED
        if (isConnected) {
            VpnController.stopNative(this)
        } else {
            if (VpnService.prepare(this) != null) {
                val intent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivityAndCollapse(intent)
                return
            }

            val intent = Intent(this, DnsVpnService::class.java).apply {
                action = DnsVpnService.ACTION_START
                putExtra(DnsVpnService.EXTRA_START_TICKET, VpnRuntime.nextStartTicket())
                applyLastConfig(this@DnsTileService, this)
            }
            try {
                ContextCompat.startForegroundService(this, intent)
            } catch (_: Exception) {
                val appIntent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivityAndCollapse(appIntent)
            }
        }
        updateTileUI()
    }

    private fun updateTileUI() {
        val tile = qsTile ?: return
        val isConnected = VpnRuntime.snapshot.phase == VpnPhase.CONNECTED
        tile.state = if (isConnected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = if (isConnected) "DNS Changer" else "DNS Changer"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (isConnected) "Active" else "Off"
        }
        tile.updateTile()
    }
}

fun applyLastConfig(context: Context, intent: Intent) {
    val json = try {
        context.getSharedPreferences(VpnLastConfig.PREFS, Context.MODE_PRIVATE)
            .getString(VpnLastConfig.KEY, null)
    } catch (_: Exception) { null }
    val config = VpnLastConfig.fromJson(json)
    if (config != null) {
        intent.putStringArrayListExtra(DnsVpnService.EXTRA_ADDRESSES, ArrayList(config.encodedAddresses))
        intent.putStringArrayListExtra(DnsVpnService.EXTRA_ALLOWED_PACKAGES, ArrayList(config.allowedPackages))
        intent.putStringArrayListExtra(DnsVpnService.EXTRA_DISALLOWED_PACKAGES, ArrayList(config.disallowedPackages))
        intent.putExtra(DnsVpnService.EXTRA_ENABLE_IPV6, config.enableIpv6)
        intent.putExtra(DnsVpnService.EXTRA_AUTO_RECONNECT, config.autoReconnect)
        intent.putExtra(DnsVpnService.EXTRA_TIMEOUT_MS, config.timeoutMs)
        intent.putExtra(DnsVpnService.EXTRA_FALLBACK_SECONDARY, config.fallbackSecondary)
        intent.putExtra(DnsVpnService.EXTRA_DNS_LEAK_PROTECTION, config.dnsLeakProtection)
        intent.putExtra(DnsVpnService.EXTRA_PORT, 53)
    } else {
        intent.putStringArrayListExtra(DnsVpnService.EXTRA_ADDRESSES, arrayListOf("1.1.1.1", "1.0.0.1"))
        intent.putExtra(DnsVpnService.EXTRA_PORT, 53)
        intent.putExtra(DnsVpnService.EXTRA_ENABLE_IPV6, true)
    }
}
