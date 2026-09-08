package com.dnschanger.app

import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicLong

/** Process-local authoritative status. No server addresses or URLs in events. */
data class VpnSnapshot(val phase: VpnPhase, val errorCode: String?, val revision: Long) {
    fun toMap(notificationsEnabled: Boolean): Map<String, Any?> = mapOf(
        "state" to phase.wireName,
        "errorCode" to errorCode,
        "revision" to revision,
        "notificationsEnabled" to notificationsEnabled
    )
}

object VpnRuntime {
    @Volatile
    var snapshot = VpnSnapshot(VpnPhase.DISCONNECTED, null, 0)
        private set

    @Volatile
    var serviceAlive = false

    private val listeners = CopyOnWriteArraySet<(VpnSnapshot) -> Unit>()
    private val startTicket = AtomicLong(0)

    fun nextStartTicket(): Long = startTicket.incrementAndGet()
    fun cancelQueuedStarts() { startTicket.incrementAndGet() }
    fun isCurrentStart(ticket: Long): Boolean = ticket >= 0 && ticket == startTicket.get()

    // State changes originate on the main thread; reader failures are posted
    // there by DnsVpnService and checked against the current tunnel generation.
    fun publish(phase: VpnPhase, errorCode: String? = null) {
        snapshot = VpnSnapshot(phase, errorCode, snapshot.revision + 1)
        listeners.forEach { listener ->
            // A detached Flutter engine must not take down a healthy VPN.
            try { listener(snapshot) } catch (_: Exception) { }
        }
    }

    fun addListener(listener: (VpnSnapshot) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (VpnSnapshot) -> Unit) {
        listeners.remove(listener)
    }
}
