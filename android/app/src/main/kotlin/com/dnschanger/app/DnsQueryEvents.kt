package com.dnschanger.app

import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

object DnsQueryEvents {
    const val CHANNEL = "com.dnschanger.app/dns_queries"

    @Volatile
    var loggingEnabled: Boolean = false

    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private val windowStart = AtomicLong(0)
    private val windowCount = AtomicInteger(0)

    fun addListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    fun emit(dnsMessage: ByteArray, serverIndex: Int, latencyMs: Long) {
        if (!loggingEnabled || listeners.isEmpty()) return
        val now = System.currentTimeMillis()
        val start = windowStart.get()
        if (now - start >= 1000) {
            windowStart.set(now)
            windowCount.set(0)
        }
        if (windowCount.incrementAndGet() > 20) return
        val q = PacketUtils.parseQuestion(dnsMessage) ?: return
        val event = mapOf(
            "domain" to q.name,
            "qtype" to PacketUtils.qtypeName(q.qtype),
            "serverIndex" to serverIndex,
            "latencyMs" to latencyMs.toInt().coerceAtLeast(0),
            "ts" to now
        )
        listeners.forEach { listener ->
            try { listener(event) } catch (_: Exception) {}
        }
    }
}
