package com.dnschanger.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object VpnNotifications {
    const val CHANNEL_ID = "dns_vpn_channel"
    const val ID = 1

    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "وضعیت اتصال DNS", NotificationManager.IMPORTANCE_LOW)
            channel.description = "کنترل توقف موقت، ازسرگیری و قطع اتصال DNS"
            // Keep the channel ID stable and respect the user's channel settings.
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    fun enabled(context: Context): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL_ID)
            if (channel?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    fun settingsIntent(context: Context): Intent {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val blockedChannel = manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
            return Intent(if (blockedChannel) Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS else Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                if (blockedChannel) putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
            }
        }
        return Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
    }

    fun build(context: Context, phase: VpnPhase, errorCode: String? = null): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val openApp = PendingIntent.getActivity(context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), flags)
        fun command(action: String, requestCode: Int, foreground: Boolean = false): PendingIntent {
            val intent = Intent(context, DnsVpnService::class.java).setAction(action)
            return if (foreground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(context, requestCode, intent, flags)
            } else {
                PendingIntent.getService(context, requestCode, intent, flags)
            }
        }
        val title = when (phase) {
            VpnPhase.CONNECTED -> "DNS Changer — متصل"
            VpnPhase.PAUSED -> "DNS Changer — توقف موقت"
            else -> "DNS Changer — در حال اتصال"
        }
        val text = when {
            errorCode == "permission_required" -> "برای دادن اجازهٔ VPN، برنامه را باز کنید."
            phase == VpnPhase.PAUSED -> "DNS انتخابی موقتاً غیرفعال است؛ برای ادامه ازسرگیری را بزنید."
            phase == VpnPhase.CONNECTED -> "DNS فعال است."
            else -> "در حال برقراری تونل VPN…"
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_vpn_status)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openApp)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        when (phase) {
            VpnPhase.CONNECTED -> builder.addAction(android.R.drawable.ic_media_pause, "توقف موقت", command(DnsVpnService.ACTION_PAUSE, 1))
            VpnPhase.PAUSED -> builder.addAction(android.R.drawable.ic_media_play,
                if (errorCode == "permission_required") "باز کردن برنامه" else "ازسرگیری",
                if (errorCode == "permission_required") openApp else command(DnsVpnService.ACTION_RESUME, 2, foreground = true))
            else -> Unit
        }
        builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "قطع اتصال", command(DnsVpnService.ACTION_STOP, 3))
        // Deliberately omit DNS addresses, backend URLs and repository metadata.
        return builder.build()
    }
}
