package com.dnschanger.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

class DnsVpnService : VpnService() {
    companion object {
        private const val TAG = "DnsVpnService"
        const val ACTION_START = "com.dnschanger.app.START"
        const val ACTION_STOP = "com.dnschanger.app.STOP"
        const val EXTRA_ADDRESSES = "addresses"
        const val EXTRA_PORT = "port"
        const val EXTRA_ALLOWED_PACKAGES = "allowed_packages"
        private const val CHANNEL_ID = "dns_vpn_channel"
        private const val NOTIFICATION_ID = 1
        private const val MTU = 1500
        private const val WATCHDOG_IDLE_MS = 5 * 60_000L

        const val VPN_IPV4 = "10.0.0.2"
        const val VPN_DNS_IPV4 = "10.0.0.1"
        const val VPN_IPV6 = "2001:db8::2"
        const val VPN_DNS_IPV6 = "2001:db8::1"

        // Common public resolvers that apps may hardcode. We route them so their
        // queries are also captured and answered by the chosen upstream.
        private val EXTRA_V4_RESOLVERS = listOf(
            "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15"
        )
        private val EXTRA_V6_RESOLVERS = listOf(
            "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888",
            "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9", "2620:119:35::35", "2620:119:53::53"
        )

        @Volatile
        var running = false
            private set

        @Volatile
        var currentUpstreams: List<String> = emptyList()
            private set
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var output: FileOutputStream? = null
    private var resolver: DnsResolver? = null
    private var readerThread: Thread? = null
    private var upstreams: List<Pair<String, Int>> = emptyList()
    private var currentPort: Int = 53
    private var currentAllowedPackages: List<String> = emptyList()
    private val tcpProxies = ConcurrentHashMap<Int, TcpProxy>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lastTraffic = AtomicLong(0)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        when (intent.action) {
            ACTION_START -> {
                val addresses = intent.getStringArrayListExtra(EXTRA_ADDRESSES) ?: arrayListOf()
                val port = intent.getIntExtra(EXTRA_PORT, 53)
                val allowedPackages = intent.getStringArrayListExtra(EXTRA_ALLOWED_PACKAGES) ?: arrayListOf()
                startInternal(addresses, port, allowedPackages)
            }
            ACTION_STOP -> stopInternal()
        }
        return START_NOT_STICKY
    }

    private fun startInternal(addresses: List<String>, port: Int, allowedPackages: List<String>) {
        if (running) {
            stopInternal()
            Thread.sleep(200)
        }
        currentPort = port
        currentAllowedPackages = allowedPackages
        upstreams = addresses
            .mapNotNull { parseHostPort(it, port) }
            .ifEmpty { listOf(parseHostPort("1.1.1.1", 53)!!) }
        currentUpstreams = upstreams.map { it.first }

        val builder = Builder()
        builder.setSession("DNS Changer")
        builder.setMtu(MTU)
        builder.addAddress(VPN_IPV4, 32)
        builder.addDnsServer(VPN_DNS_IPV4)
        builder.addRoute(VPN_DNS_IPV4, 32)
        try {
            builder.addAddress(VPN_IPV6, 128)
            builder.addDnsServer(VPN_DNS_IPV6)
            builder.addRoute(VPN_DNS_IPV6, 128)
        } catch (_: Exception) {
            Log.w(TAG, "IPv6 not available")
        }
        // Route the real upstream IPs and common resolvers so hardcoded queries
        // are captured too.
        collectResolverRoutes(builder)
        // Never route our own traffic (prevents loops).
        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
        }
        if (allowedPackages.isNotEmpty()) {
            for (pkg in allowedPackages) {
                try {
                    builder.addAllowedApplication(pkg)
                } catch (e: Exception) {
                    Log.w(TAG, "addAllowedApplication($pkg) failed", e)
                }
            }
        }
        builder.setBlocking(true)
        try {
            vpnInterface = builder.establish()
        } catch (e: Exception) {
            Log.e(TAG, "establish failed", e)
            stopInternal()
            return
        }
        if (vpnInterface == null) {
            stopInternal()
            return
        }
        output = FileOutputStream(vpnInterface!!.fileDescriptor)
        startForeground(NOTIFICATION_ID, buildNotification())
        running = true
        lastTraffic.set(System.currentTimeMillis())
        registerNetworkCallback()

        resolver = DnsResolver(upstreams) { pending, response ->
            onDnsResponse(pending, response)
        }
        resolver!!.start()

        readerThread = Thread({
            runReader(FileInputStream(vpnInterface!!.fileDescriptor))
        }, "DnsVpnReader")
        readerThread!!.start()

        mainHandler.postDelayed({ watchdogTick() }, WATCHDOG_IDLE_MS)
    }

    private fun collectResolverRoutes(builder: Builder) {
        val seen = mutableSetOf<String>()
        val addRoute = { ip: String ->
            if (ip.isNotBlank() && seen.add(ip)) {
                try {
                    val prefix = if (ip.contains(":")) 128 else 32
                    builder.addRoute(ip, prefix)
                } catch (_: Exception) {
                }
            }
        }
        for (u in upstreams) addRoute(u.first)
        EXTRA_V4_RESOLVERS.forEach(addRoute)
        EXTRA_V6_RESOLVERS.forEach(addRoute)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        try {
            val network = cm.activeNetwork ?: return
            val props: LinkProperties = cm.getLinkProperties(network) ?: return
            for (dns in props.dnsServers) {
                addRoute(dns.hostAddress ?: continue)
            }
        } catch (_: Exception) {
        }
    }

    private fun registerNetworkCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                    // Re-establish so newly added DNS routes are captured.
                    if (running) {
                        mainHandler.post { restartInterface() }
                    }
                }
            }
            cm.registerDefaultNetworkCallback(networkCallback!!)
        } catch (_: Exception) {
        }
    }

    private fun watchdogTick() {
        if (!running) return
        if (System.currentTimeMillis() - lastTraffic.get() > WATCHDOG_IDLE_MS) {
            Log.w(TAG, "Watchdog: re-establishing idle interface")
            restartInterface()
        } else {
            mainHandler.postDelayed({ watchdogTick() }, WATCHDOG_IDLE_MS)
        }
    }

    private fun restartInterface() {
        val addrs = upstreams.map { "${it.first}:${it.second}" }
        startInternal(addrs, currentPort, currentAllowedPackages)
    }

    private fun runReader(input: FileInputStream) {
        val packet = ByteArray(32767)
        while (running && !Thread.interrupted()) {
            val len = try {
                input.read(packet)
            } catch (_: Exception) {
                break
            }
            if (len <= 0) continue
            lastTraffic.set(System.currentTimeMillis())
            val parsed = PacketUtils.parse(packet, len) ?: continue
            if (parsed.dstPort != 53) continue
            when (parsed.protocol) {
                PacketUtils.PROTO_UDP -> {
                    val payload = packet.copyOfRange(parsed.transportOffset + 8, len)
                    if (payload.size >= 12) {
                        resolver?.resolve(payload, parsed.srcAddr, parsed.srcPort, parsed.dstAddr)
                    }
                }
                PacketUtils.PROTO_TCP -> {
                    val key = parsed.srcPort
                    val proxy = tcpProxies.getOrPut(key) {
                        TcpProxy(
                            parsed.srcAddr, parsed.srcPort, parsed.dstAddr, upstreams,
                            { bytes -> writeToTun(bytes) },
                            { p ->
                                tcpProxies.remove(key)
                                p.close()
                            }
                        )
                    }
                    proxy.feed(packet, parsed.transportOffset, len, parsed.tcpFlags)
                }
            }
        }
    }

    private fun onDnsResponse(pending: DnsResolver.PendingQuery, response: ByteArray) {
        val pkt = PacketUtils.buildUdpResponse(pending.dstAddr, pending.srcAddr, 53, pending.srcPort, response)
        writeToTun(pkt)
    }

    private fun writeToTun(bytes: ByteArray) {
        val out = output ?: return
        synchronized(out) {
            try {
                out.write(bytes)
                out.flush()
            } catch (_: Exception) {
            }
        }
    }

    private fun stopInternal() {
        running = false
        currentUpstreams = emptyList()
        try {
            networkCallback?.let {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                    ?.unregisterNetworkCallback(it)
            }
        } catch (_: Exception) {
        }
        networkCallback = null
        resolver?.stop()
        resolver = null
        tcpProxies.values.forEach { it.close() }
        tcpProxies.clear()
        try {
            output?.close()
        } catch (_: Exception) {
        }
        output = null
        try {
            vpnInterface?.close()
        } catch (_: Exception) {
        }
        vpnInterface = null
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        stopInternal()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        createChannel()
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, DnsVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("DNS Changer active")
            .setContentText("DNS: " + currentUpstreams.joinToString(", "))
            .setContentIntent(contentIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", stopIntent)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "DNS Changer VPN", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shown while the secure DNS tunnel is running"
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun parseHostPort(host: String, defaultPort: Int): Pair<String, Int>? {
        val trimmed = host.trim()
        if (trimmed.isEmpty()) return null
        return try {
            if (trimmed.startsWith("[")) {
                val end = trimmed.indexOf(']')
                val h = trimmed.substring(1, end)
                val p = trimmed.substring(end + 1).removePrefix(":").toIntOrNull() ?: defaultPort
                h to p
            } else if (trimmed.count { it == ':' } == 1 && trimmed.substringAfter(':').toIntOrNull() != null) {
                val parts = trimmed.split(':')
                parts[0] to parts[1].toInt()
            } else if (trimmed.contains(':')) {
                trimmed to defaultPort
            } else {
                trimmed to defaultPort
            }
        } catch (_: Exception) {
            null
        }
    }
}
