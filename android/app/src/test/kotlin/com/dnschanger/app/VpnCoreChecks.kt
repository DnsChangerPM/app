package com.dnschanger.app

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Same regression cases run by JUnit in Gradle or directly on a JVM without an emulator. */
object VpnCoreChecks {
    private val config = VpnConfig.parse(listOf("1.1.1.1", "2606:4700:4700::1111"), 53, emptyList())

    private class Platform : VpnPlatform {
        val calls = mutableListOf<String>()
        val opened = mutableListOf<VpnConfig>()
        var foreground = false
        var tunnel = false
        var onOpen: (() -> Unit)? = null
        var failOpen: String? = null
        override fun startForeground(phase: VpnPhase) { calls.add("foreground"); foreground = true }
        override fun updateNotification(phase: VpnPhase, errorCode: String?) { calls.add("notify:${phase.wireName}") }
        override fun openTunnel(config: VpnConfig) {
            check(foreground) { "TUN opened without foreground notification" }
            calls.add("open")
            onOpen?.invoke()
            failOpen?.let { throw VpnFailure(it) }
            opened.add(config)
            tunnel = true
        }
        override fun closeTunnel() { calls.add("close"); tunnel = false }
        override fun stopForeground() { calls.add("remove-notification"); foreground = false }
        override fun stopService() { calls.add("stop-self") }
    }

    private fun failure(code: String, block: () -> Unit) {
        try {
            block()
            error("Expected VpnFailure($code)")
        } catch (error: VpnFailure) {
            check(error.code == code)
        }
    }

    fun cases(): List<Pair<String, () -> Unit>> = listOf(
        "connected is reported only after foreground and successful TUN establishment" to {
            val platform = Platform()
            val phases = mutableListOf<VpnPhase>()
            val session = VpnSession(platform) { state, _ -> phases.add(state) }
            platform.onOpen = { check(phases.last() == VpnPhase.CONNECTING) }
            session.start(config)
            check(platform.calls.indexOf("foreground") < platform.calls.indexOf("open"))
            check(phases == listOf(VpnPhase.CONNECTING, VpnPhase.CONNECTED))
            check(platform.tunnel && platform.foreground)
        },
        "failed establish is never reported as connected" to {
            val platform = Platform().apply { failOpen = "establish_failed" }
            val phases = mutableListOf<VpnPhase>()
            var error: String? = null
            val session = VpnSession(platform) { state, code -> phases.add(state); error = code }
            session.start(config)
            check(VpnPhase.CONNECTED !in phases)
            check(session.phase == VpnPhase.ERROR && error == "establish_failed")
            check(session.config == null && !platform.tunnel && !platform.foreground)
            check(platform.calls.count { it == "stop-self" } == 1)
        },
        "pause keeps the service and notification but closes the tunnel" to {
            val platform = Platform()
            val session = VpnSession(platform) { _, _ -> }
            session.start(config)
            session.pause()
            check(session.phase == VpnPhase.PAUSED && session.config == config)
            check(!platform.tunnel && platform.foreground)
            check("remove-notification" !in platform.calls && "stop-self" !in platform.calls)
            check(platform.calls.last() == "notify:paused")
            val before = platform.calls.size
            session.pause()
            check(platform.calls.size == before)
        },
        "resume restores the exact DNS and per-app settings without recreating the service" to {
            val focused = VpnConfig.parse(listOf("[2606:4700:4700::1111]:5353"), 53, listOf("com.example.game"))
            val platform = Platform()
            val session = VpnSession(platform) { _, _ -> }
            session.start(focused)
            session.pause()
            session.resume()
            check(session.phase == VpnPhase.CONNECTED && platform.tunnel)
            check(platform.opened == listOf(focused, focused))
            check("stop-self" !in platform.calls)
            val before = platform.calls.size
            session.resume()
            check(platform.calls.size == before)
        },
        "full disconnect removes notification and makes stale resume a no-op" to {
            val platform = Platform()
            val session = VpnSession(platform) { _, _ -> }
            session.start(config)
            session.pause()
            session.stop()
            check(session.phase == VpnPhase.DISCONNECTED && session.config == null)
            check(!platform.foreground && !platform.tunnel)
            check(platform.calls.last() == "stop-self")
            val before = platform.calls.size
            session.resume()
            check(platform.calls.size == before)
        },
        "network rebuild never calls stopSelf or removes the foreground notification" to {
            val platform = Platform()
            val session = VpnSession(platform) { _, _ -> }
            session.start(config)
            repeat(3) { session.reconnect() }
            check(platform.opened.size == 4 && platform.foreground && platform.tunnel)
            check("stop-self" !in platform.calls && "remove-notification" !in platform.calls)
        },
        "network changes cannot auto-resume a paused connection" to {
            val platform = Platform()
            val session = VpnSession(platform) { _, _ -> }
            session.start(config)
            session.pause()
            val before = platform.calls.size
            session.reconnect()
            check(platform.calls.size == before && session.phase == VpnPhase.PAUSED)
        },
        "destroy closes resources but preserves the preceding failure" to {
            val platform = Platform().apply { failOpen = "target_app_missing" }
            val phases = mutableListOf<VpnPhase>()
            val session = VpnSession(platform) { state, _ -> phases.add(state) }
            session.start(config)
            session.destroy()
            check(session.phase == VpnPhase.ERROR && phases.last() == VpnPhase.ERROR)
            check(!platform.foreground && !platform.tunnel)
            check(platform.calls.count { it == "stop-self" } == 1)
        },
        "destroy of a stopped session does not overwrite a newer permission request" to {
            val session = VpnSession(Platform()) { phase, error -> VpnRuntime.publish(phase, error) }
            session.start(config)
            session.stop()
            VpnRuntime.publish(VpnPhase.REQUESTING_PERMISSION)
            session.destroy()
            check(VpnRuntime.snapshot.phase == VpnPhase.REQUESTING_PERMISSION)
            VpnRuntime.publish(VpnPhase.DISCONNECTED)
        },
        "consent-required resume stays paused with its configuration" to {
            val platform = Platform()
            var error: String? = null
            val session = VpnSession(platform) { _, code -> error = code }
            session.start(config)
            session.pause()
            session.permissionRequired()
            check(session.phase == VpnPhase.PAUSED && session.config == config)
            check(error == "permission_required" && !platform.tunnel && platform.foreground)
        },
        "initial and duplicate link callbacks do not cause reconnect loops" to {
            val tracker = UnderlyingNetworkTracker()
            check(!tracker.changed("wifi|dns-a"))
            check(!tracker.changed("wifi|dns-a"))
            check(tracker.changed("mobile|dns-b"))
            check(!tracker.changed("mobile|dns-b"))
            tracker.reset("mobile|dns-b")
            check(!tracker.changed("mobile|dns-b"))
            check(tracker.changed("mobile|dns-c"))
            tracker.reset(null)
            check(!tracker.changed("wifi|dns-a"))
        },
        "per-app scope never mixes allowed and disallowed lists" to {
            val allowed = mutableListOf<String>()
            val disallowed = mutableListOf<String>()
            applyAppScope(emptyList(), "com.dnschanger.app", { allowed.add(it) }, { disallowed.add(it) })
            check(allowed.isEmpty() && disallowed == listOf("com.dnschanger.app"))
            disallowed.clear()
            applyAppScope(listOf("com.example.game"), "com.dnschanger.app", { allowed.add(it) }, { disallowed.add(it) })
            check(allowed == listOf("com.example.game") && disallowed.isEmpty())
            failure("invalid_target") {
                applyAppScope(listOf("com.dnschanger.app"), "com.dnschanger.app", {}, {})
            }
        },
        "IPv4 IPv6 and custom ports survive pause resume serialization" to {
            val config = VpnConfig.parse(listOf("1.1.1.1:5353", "[2606:4700:4700::1111]:9953"), 53, listOf("com.example.game"))
            check(config.upstreams.map { it.second } == listOf(5353, 9953))
            check(VpnConfig.parse(config.encodedAddresses, 1, config.allowedPackages) == config)
            for (value in listOf("999.1.1.1", "1.1.1", "dns.example", "https://example.com", "[::1]bad", "[::1]:65536", "1.1.1.1:0", "::", "224.0.0.1")) {
                failure("invalid_dns") { VpnConfig.parse(listOf(value), 53, emptyList()) }
            }
            failure("invalid_dns") { VpnConfig.parse(emptyList(), 53, emptyList()) }
            failure("invalid_target") { VpnConfig.parse(listOf("1.1.1.1"), 53, listOf(" ")) }
        },
        "stop invalidates queued starts while a newer request gets its own ticket" to {
            val first = VpnRuntime.nextStartTicket()
            check(VpnRuntime.isCurrentStart(first))
            VpnRuntime.cancelQueuedStarts()
            check(!VpnRuntime.isCurrentStart(first))
            val next = VpnRuntime.nextStartTicket()
            check(next > first && VpnRuntime.isCurrentStart(next))
            check(!VpnRuntime.isCurrentStart(-1))
        },
        "status events are versioned and do not expose addresses or URLs" to {
            val previous = VpnRuntime.snapshot.revision
            var received = 0
            val detached: (VpnSnapshot) -> Unit = { throw IllegalStateException("detached engine") }
            val observer: (VpnSnapshot) -> Unit = { received++ }
            VpnRuntime.addListener(detached)
            VpnRuntime.addListener(observer)
            try {
                VpnRuntime.publish(VpnPhase.CONNECTED)
                val data = VpnRuntime.snapshot.toMap(false)
                check(VpnRuntime.snapshot.revision > previous && received == 1)
                check(data.keys == setOf("state", "errorCode", "revision", "notificationsEnabled"))
                check(data["notificationsEnabled"] == false)
            } finally {
                VpnRuntime.removeListener(detached)
                VpnRuntime.removeListener(observer)
                VpnRuntime.publish(VpnPhase.DISCONNECTED)
            }
        },
        "UDP socket is protected before traffic and is closed on stop" to {
            val server = DatagramSocket(0, InetAddress.getByName("127.0.0.1")).apply { soTimeout = 3000 }
            val answered = CountDownLatch(1)
            var protectedSocket: DatagramSocket? = null
            val resolver = DnsResolver(listOf("127.0.0.1" to server.localPort), { socket -> protectedSocket = socket; true }) { pending, data ->
                if (pending.id == 0x1234 && data.size == 12) answered.countDown()
            }
            val echo = Thread {
                try {
                    val packet = DatagramPacket(ByteArray(512), 512)
                    server.receive(packet)
                    check(protectedSocket != null)
                    server.send(packet)
                } catch (_: Exception) { }
            }
            try {
                resolver.start()
                echo.start()
                val query = ByteArray(12).apply { this[0] = 0x12; this[1] = 0x34 }
                resolver.resolve(query, byteArrayOf(10, 0, 0, 2), 12345, byteArrayOf(10, 0, 0, 1))
                check(answered.await(3, TimeUnit.SECONDS)) { "No UDP DNS response" }
            } finally {
                resolver.stop()
                server.close()
                echo.join(1000)
            }
            check(protectedSocket?.isClosed == true)
        },
        "failed socket protection closes resources instead of creating a DNS loop" to {
            var socket: DatagramSocket? = null
            failure("socket_protection_failed") {
                DnsResolver(listOf("127.0.0.1" to 53), { current -> socket = current; false }) { _, _ -> }
            }
            check(socket?.isClosed == true)
        }
    )

    @JvmStatic
    fun main(args: Array<String>) {
        val tests = cases()
        tests.forEach { (name, run) -> run(); println("PASS: $name") }
        println("${tests.size} VPN core regression checks passed.")
    }
}
