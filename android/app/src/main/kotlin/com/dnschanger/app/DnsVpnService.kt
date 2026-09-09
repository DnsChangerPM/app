package com.dnschanger.app

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import androidx.core.app.ServiceCompat
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

class DnsVpnService : VpnService() {
    companion object {
        const val ACTION_START = "com.dnschanger.app.START"
        const val ACTION_PAUSE = "com.dnschanger.app.PAUSE"
        const val ACTION_RESUME = "com.dnschanger.app.RESUME"
        const val ACTION_STOP = "com.dnschanger.app.STOP"
        const val EXTRA_ADDRESSES = "addresses"
        const val EXTRA_PORT = "port"
        const val EXTRA_ALLOWED_PACKAGES = "allowed_packages"
        const val EXTRA_DISALLOWED_PACKAGES = "disallowed_packages"
        const val EXTRA_ENABLE_IPV6 = "enable_ipv6"
        const val EXTRA_START_TICKET = "start_ticket"
        private const val MTU = 1500

        const val VPN_IPV4 = "10.0.0.2"
        const val VPN_DNS_IPV4 = "10.0.0.1"
        const val VPN_IPV6 = "2001:db8::2"
        const val VPN_DNS_IPV6 = "2001:db8::1"

        private val EXTRA_RESOLVERS = listOf(
            "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15",
            "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888",
            "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9", "2620:119:35::35", "2620:119:53::53"
        )
    }

    private class Tunnel(val fd: ParcelFileDescriptor, val generation: Long, val config: VpnConfig) {
        val input = FileInputStream(fd.fileDescriptor)
        val output = FileOutputStream(fd.fileDescriptor)
        val tcp = ConcurrentHashMap<String, TcpProxy>()
        var resolver: DnsResolver? = null
        var reader: Thread? = null
    }

    @Volatile private var tunnel: Tunnel? = null
    private val generation = AtomicLong(0)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val networkTracker = UnderlyingNetworkTracker()
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var foreground = false
    private lateinit var session: VpnSession
    private val reconnect = Runnable {
        if (tunnel != null && session.phase == VpnPhase.CONNECTED &&
            VpnRuntime.snapshot.phase == VpnPhase.CONNECTED) session.reconnect()
    }

    override fun onCreate() {
        super.onCreate()
        VpnRuntime.serviceAlive = true
        VpnNotifications.createChannel(this)
        session = VpnSession(object : VpnPlatform {
            override fun startForeground(phase: VpnPhase) = showForeground(phase)
            override fun updateNotification(phase: VpnPhase, errorCode: String?) = showNotification(phase, errorCode)
            override fun openTunnel(config: VpnConfig) = establishTunnel(config)
            override fun closeTunnel() = releaseTunnel()
            override fun stopForeground() = removeNotification()
            override fun stopService() = stopSelf()
        }) { phase, error ->
            VpnRuntime.publish(phase, error)
            DnsTileService.updateTileState(this, phase == VpnPhase.CONNECTED)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            if (session.config == null) session.stop()
            return START_NOT_STICKY
        }
        try {
            when (intent.action) {
                ACTION_START -> {
                    if (!VpnRuntime.isCurrentStart(intent.getLongExtra(EXTRA_START_TICKET, -1))) {
                        discardQueuedStart(startId)
                        return START_NOT_STICKY
                    }
                    // Fulfil startForegroundService's deadline even for invalid input
                    showForeground(VpnPhase.CONNECTING)
                    val config = VpnConfig.parse(
                        intent.getStringArrayListExtra(EXTRA_ADDRESSES) ?: emptyList(),
                        intent.getIntExtra(EXTRA_PORT, 53),
                        intent.getStringArrayListExtra(EXTRA_ALLOWED_PACKAGES) ?: emptyList(),
                        intent.getStringArrayListExtra(EXTRA_DISALLOWED_PACKAGES) ?: emptyList(),
                        intent.getBooleanExtra(EXTRA_ENABLE_IPV6, true)
                    )
                    session.start(config)
                }
                ACTION_PAUSE -> {
                    if (session.config == null) session.stop() else session.pause()
                }
                ACTION_RESUME -> {
                    val accepted = if (intent.hasExtra(EXTRA_START_TICKET)) {
                        VpnRuntime.isCurrentStart(intent.getLongExtra(EXTRA_START_TICKET, -1))
                    } else {
                        VpnRuntime.snapshot.phase == VpnPhase.PAUSED
                    }
                    if (!accepted) {
                        discardQueuedStart(startId)
                        return START_NOT_STICKY
                    }
                    showForeground(VpnPhase.CONNECTING)
                    when {
                        session.config == null -> session.stop("no_session")
                        session.phase == VpnPhase.CONNECTED -> showNotification(VpnPhase.CONNECTED)
                        VpnService.prepare(this) != null -> session.permissionRequired()
                        else -> session.resume()
                    }
                }
                ACTION_STOP -> {
                    VpnRuntime.cancelQueuedStarts()
                    session.stop()
                }
                else -> if (session.config == null) session.stop()
            }
        } catch (failure: VpnFailure) {
            session.stop(failure.code)
        } catch (_: Exception) {
            session.stop("start_failed")
        }
        return START_NOT_STICKY
    }

    private fun discardQueuedStart(startId: Int) {
        if (session.config == null) {
            showForeground(VpnPhase.CONNECTING)
            removeNotification()
            stopSelf(startId)
        }
    }

    private fun establishTunnel(config: VpnConfig) {
        if (VpnService.prepare(this) != null) throw VpnFailure("permission_required")
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork
        val properties = network?.let { cm.getLinkProperties(it) }
        val fingerprint = if (network != null && properties != null) fingerprint(network, properties) else null

        val builder = Builder()
            .setSession("DNS Changer")
            .setMtu(MTU)
            .addAddress(VPN_IPV4, 32)
            .addDnsServer(VPN_DNS_IPV4)
            .addRoute(VPN_DNS_IPV4, 32)
            .setBlocking(true)
        builder.setConfigureIntent(PendingIntent.getActivity(this, 4, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))

        if (config.enableIpv6) {
            try {
                builder.addAddress(VPN_IPV6, 128)
                builder.addDnsServer(VPN_DNS_IPV6)
                builder.addRoute(VPN_DNS_IPV6, 128)
            } catch (_: IllegalArgumentException) {
                // IPv4 can still work on a device without IPv6 tunnel support.
            }
        }

        val routes = (config.upstreams.map { it.first } + EXTRA_RESOLVERS +
            (properties?.dnsServers?.mapNotNull { it.hostAddress } ?: emptyList())).distinct()
        for (ip in routes) {
            if (!config.enableIpv6 && ip.contains(':')) continue
            try { builder.addRoute(ip, if (ip.contains(':')) 128 else 32) } catch (_: IllegalArgumentException) { }
        }

        applyAppScope(
            config.allowedPackages,
            config.disallowedPackages,
            packageName,
            allow = { pkg ->
                try {
                    builder.addAllowedApplication(pkg)
                } catch (_: PackageManager.NameNotFoundException) {
                    throw VpnFailure("target_app_missing")
                }
            },
            disallow = { pkg ->
                try {
                    builder.addDisallowedApplication(pkg)
                } catch (_: Exception) {}
            }
        )

        val fd = builder.establish() ?: throw VpnFailure("establish_failed")
        val connection = try { Tunnel(fd, generation.incrementAndGet(), config) } catch (error: Exception) {
            fd.close()
            throw error
        }
        tunnel = connection
        connection.resolver = DnsResolver(config.upstreams, { protect(it) }) { pending, response ->
            val packet = PacketUtils.buildUdpResponse(pending.dstAddr, pending.srcAddr, 53, pending.srcPort, response)
            writeToTun(packet, connection.generation)
        }
        connection.resolver!!.start()
        connection.reader = Thread({ readTunnel(connection) }, "DnsVpnReader").also { it.start() }
        watchNetwork(connection.generation, fingerprint)
    }

    private fun readTunnel(connection: Tunnel) {
        val packet = ByteArray(32767)
        try {
            while (isCurrent(connection.generation) && !Thread.currentThread().isInterrupted) {
                val length = connection.input.read(packet)
                if (length < 0) break
                if (length == 0 || !isCurrent(connection.generation)) continue
                val parsed = PacketUtils.parse(packet, length) ?: continue
                if (parsed.dstPort != 53) continue
                when (parsed.protocol) {
                    PacketUtils.PROTO_UDP -> {
                        val offset = parsed.transportOffset + 8
                        if (length < offset + 12) continue
                        connection.resolver?.resolve(packet.copyOfRange(offset, length), parsed.srcAddr, parsed.srcPort, parsed.dstAddr)
                    }
                    PacketUtils.PROTO_TCP -> {
                        val key = "${parsed.srcAddr.joinToString(":")}|${parsed.srcPort}|${parsed.dstAddr.joinToString(":")}"
                        val proxy = connection.tcp.getOrPut(key) {
                            TcpProxy(parsed.srcAddr, parsed.srcPort, parsed.dstAddr, connection.config.upstreams,
                                { protect(it) },
                                { writeToTun(it, connection.generation) },
                                { closed -> connection.tcp.remove(key, closed); closed.close() })
                        }
                        if (!isCurrent(connection.generation)) {
                            connection.tcp.remove(key, proxy)
                            proxy.close()
                            continue
                        }
                        proxy.feed(packet, parsed.transportOffset, length, parsed.tcpFlags)
                    }
                }
            }
        } catch (_: Exception) {
            // Do not log addresses from socket/IO exceptions.
        } finally {
            tunnelFailed(connection.generation)
        }
    }

    private fun writeToTun(bytes: ByteArray, token: Long) {
        val connection = tunnel ?: return
        if (connection.generation != token) return
        synchronized(connection.output) {
            if (!isCurrent(token)) return
            try {
                connection.output.write(bytes)
                connection.output.flush()
            } catch (_: Exception) {
                tunnelFailed(token)
            }
        }
    }

    private fun tunnelFailed(token: Long) {
        mainHandler.post {
            if (isCurrent(token)) session.stop("tunnel_closed")
        }
    }

    private fun isCurrent(token: Long): Boolean = tunnel?.generation == token && generation.get() == token

    private fun releaseTunnel() {
        mainHandler.removeCallbacks(reconnect)
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        networkCallback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) { } }
        networkCallback = null
        networkTracker.reset(null)
        generation.incrementAndGet()
        val old = tunnel
        tunnel = null
        if (old != null) {
            old.resolver?.stop()
            old.tcp.values.forEach { it.close() }
            old.tcp.clear()
            old.reader?.interrupt()
            try { old.input.close() } catch (_: Exception) { }
            try { old.output.close() } catch (_: Exception) { }
            try { old.fd.close() } catch (_: Exception) { }
        }
    }

    private fun fingerprint(network: Network, properties: LinkProperties): String? {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val capabilities = cm.getNetworkCapabilities(network) ?: return null
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return null
        return "${network.networkHandle}|${properties.interfaceName}|" +
            properties.dnsServers.mapNotNull { it.hostAddress }.sorted().joinToString(",") + "|" +
            properties.linkAddresses.map { it.toString() }.sorted().joinToString(",")
    }

    private fun watchNetwork(token: Long, initialFingerprint: String?) {
        networkTracker.reset(initialFingerprint)
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                val current = fingerprint(network, linkProperties) ?: return
                mainHandler.post {
                    if (!isCurrent(token) || session.phase != VpnPhase.CONNECTED ||
                        VpnRuntime.snapshot.phase == VpnPhase.CONNECTED) return@post
                    if (networkTracker.changed(current)) {
                        mainHandler.removeCallbacks(reconnect)
                        mainHandler.postDelayed(reconnect, 750)
                    }
                }
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (_: Exception) {
        }
    }

    private fun showForeground(phase: VpnPhase) {
        if (foreground) {
            showNotification(phase)
            return
        }
        try {
            val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
            ServiceCompat.startForeground(this, VpnNotifications.ID, VpnNotifications.build(this, phase), type)
            foreground = true
        } catch (_: Exception) {
            throw VpnFailure("foreground_failed")
        }
    }

    private fun showNotification(phase: VpnPhase, errorCode: String? = null) {
        if (!VpnNotifications.enabled(this)) return
        try {
            getSystemService(NotificationManager::class.java)
                .notify(VpnNotifications.ID, VpnNotifications.build(this, phase, errorCode))
        } catch (_: SecurityException) { }
    }

    private fun removeNotification() {
        if (foreground) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            foreground = false
        }
        getSystemService(NotificationManager::class.java).cancel(VpnNotifications.ID)
    }

    override fun onRevoke() {
        mainHandler.post {
            VpnRuntime.cancelQueuedStarts()
            session.stop("permission_revoked")
        }
    }

    override fun onDestroy() {
        session.destroy()
        VpnRuntime.serviceAlive = false
        if (VpnRuntime.snapshot.phase == VpnPhase.STOPPING) VpnRuntime.publish(VpnPhase.DISCONNECTED)
        mainHandler.removeCallbacksAndMessages(null)
        DnsTileService.updateTileState(this, false)
        super.onDestroy()
    }
}
