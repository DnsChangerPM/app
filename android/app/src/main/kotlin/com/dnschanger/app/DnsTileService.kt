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
        fun updateTileState(context: Context, active: Boolean) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
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
                // Launch MainActivity so user can grant VPN permission
                val intent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivityAndCollapse(intent)
                return
            }

            // Read last selected server addresses from prefs or fallback to Cloudflare
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val addresses = listOf("1.1.1.1", "1.0.0.1")
            val intent = Intent(this, DnsVpnService::class.java).apply {
                action = DnsVpnService.ACTION_START
                putExtra(DnsVpnService.EXTRA_START_TICKET, VpnRuntime.nextStartTicket())
                putStringArrayListExtra(DnsVpnService.EXTRA_ADDRESSES, ArrayList(addresses))
                putExtra(DnsVpnService.EXTRA_PORT, 53)
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
        tile.label = "DNS Changer"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (isConnected) "Active" else "Off"
        }
        tile.updateTile()
    }
}
