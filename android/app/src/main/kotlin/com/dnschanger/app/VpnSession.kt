package com.dnschanger.app

import java.net.InetAddress

/** Only stable error codes cross the platform channel, never IPs or exceptions. */
class VpnFailure(val code: String) : Exception(code)

enum class VpnPhase(val wireName: String) {
    DISCONNECTED("disconnected"),
    REQUESTING_PERMISSION("requestingPermission"),
    CONNECTING("connecting"),
    CONNECTED("connected"),
    PAUSING("pausing"),
    PAUSED("paused"),
    STOPPING("stopping"),
    ERROR("error")
}

data class VpnConfig(val upstreams: List<Pair<String, Int>>, val allowedPackages: List<String>) {
    val encodedAddresses: List<String>
        get() = upstreams.map { (host, port) ->
            if (host.contains(':')) "[$host]:$port" else "$host:$port"
        }

    companion object {
        fun parse(addresses: List<String>, port: Int, packages: List<String>): VpnConfig {
            if (port !in 1..65535 || addresses.isEmpty()) throw VpnFailure("invalid_dns")
            val upstreams = addresses.map { parseAddress(it, port) }.distinct()
            val allowed = packages.map { it.trim() }.distinct()
            if (allowed.any { it.isEmpty() }) throw VpnFailure("invalid_target")
            return VpnConfig(upstreams, allowed)
        }

        private fun parseAddress(address: String, defaultPort: Int): Pair<String, Int> {
            val value = address.trim()
            var host = value
            var port = defaultPort
            if (value.startsWith("[")) {
                val end = value.indexOf(']')
                if (end < 0) throw VpnFailure("invalid_dns")
                host = value.substring(1, end)
                val tail = value.substring(end + 1)
                if (tail.isNotEmpty()) {
                    if (!tail.startsWith(':')) throw VpnFailure("invalid_dns")
                    port = tail.drop(1).toIntOrNull() ?: throw VpnFailure("invalid_dns")
                }
            } else if (value.count { it == ':' } == 1) {
                host = value.substringBefore(':')
                port = value.substringAfter(':').toIntOrNull() ?: throw VpnFailure("invalid_dns")
            }
            if (port !in 1..65535 || host.isEmpty() || host.contains('%')) throw VpnFailure("invalid_dns")
            // A colon is required before invoking InetAddress for IPv6, so this
            // never performs a hostname lookup on the Android main thread.
            val ip = try {
                if (host.contains(':')) {
                    InetAddress.getByName(host)
                } else {
                    val parts = host.split('.')
                    if (parts.size != 4 || parts.any { !it.matches(Regex("[0-9]{1,3}")) || it.toInt() !in 0..255 }) {
                        throw VpnFailure("invalid_dns")
                    }
                    InetAddress.getByAddress(parts.map { it.toInt().toByte() }.toByteArray())
                }
            } catch (_: Exception) {
                throw VpnFailure("invalid_dns")
            }
            if (ip.isAnyLocalAddress || ip.isMulticastAddress) throw VpnFailure("invalid_dns")
            return (ip.hostAddress ?: throw VpnFailure("invalid_dns")) to port
        }
    }
}

/** Android rejects mixing allowed and disallowed application lists. */
fun applyAppScope(packages: List<String>, ownPackage: String, allow: (String) -> Unit, disallow: (String) -> Unit) {
    if (packages.isEmpty()) {
        disallow(ownPackage)
    } else {
        if (ownPackage in packages) throw VpnFailure("invalid_target")
        packages.forEach(allow)
    }
}

interface VpnPlatform {
    fun startForeground(phase: VpnPhase)
    fun updateNotification(phase: VpnPhase, errorCode: String? = null)
    fun openTunnel(config: VpnConfig)
    fun closeTunnel()
    fun stopForeground()
    fun stopService()
}

/**
 * Main-thread session state machine. Rebuilding and pausing release only tunnel
 * resources; only final disconnect/failure destroys the foreground service.
 * Kept independent of Android so the lifecycle can be regression-tested on JVM.
 */
class VpnSession(private val platform: VpnPlatform, private val publish: (VpnPhase, String?) -> Unit) {
    var phase = VpnPhase.DISCONNECTED
        private set
    var config: VpnConfig? = null
        private set

    fun start(config: VpnConfig) {
        this.config = config
        transition(VpnPhase.CONNECTING)
        try {
            // Must happen before establish(), socket creation, or any network I/O.
            platform.startForeground(VpnPhase.CONNECTING)
            platform.closeTunnel()
            platform.openTunnel(config)
            // Command acceptance is NOT proof of a working VPN interface.
            transition(VpnPhase.CONNECTED)
            platform.updateNotification(phase)
        } catch (failure: VpnFailure) {
            stop(failure.code)
        } catch (_: Exception) {
            stop("establish_failed")
        }
    }

    fun pause() {
        if (phase != VpnPhase.CONNECTED) return
        platform.closeTunnel()
        transition(VpnPhase.PAUSED)
        platform.updateNotification(phase)
    }

    fun resume() {
        if (phase != VpnPhase.PAUSED) return
        val saved = config ?: return
        start(saved)
    }

    fun permissionRequired() {
        if (phase != VpnPhase.PAUSED) return
        transition(VpnPhase.PAUSED, "permission_required")
        platform.updateNotification(phase, "permission_required")
    }

    fun reconnect() {
        if (phase != VpnPhase.CONNECTED) return
        val saved = config ?: return
        start(saved)
    }

    fun stop(errorCode: String? = null) {
        config = null
        platform.closeTunnel()
        platform.stopForeground()
        transition(if (errorCode == null) VpnPhase.DISCONNECTED else VpnPhase.ERROR, errorCode)
        platform.stopService()
    }

    fun destroy() {
        config = null
        platform.closeTunnel()
        platform.stopForeground()
        // Do not erase a useful failure, or overwrite a newer permission request
        // when onDestroy arrives after an explicit stopSelf().
        if (phase != VpnPhase.DISCONNECTED && phase != VpnPhase.ERROR) {
            transition(VpnPhase.DISCONNECTED)
        }
    }

    private fun transition(phase: VpnPhase, errorCode: String? = null) {
        this.phase = phase
        publish(phase, errorCode)
    }
}

/** Initial/duplicate link callbacks must not create a reconnect/stopSelf loop. */
class UnderlyingNetworkTracker {
    private var previous: String? = null

    fun reset(fingerprint: String?) {
        previous = fingerprint
    }

    fun changed(fingerprint: String): Boolean {
        val old = previous
        previous = fingerprint
        return old != null && old != fingerprint
    }
}
