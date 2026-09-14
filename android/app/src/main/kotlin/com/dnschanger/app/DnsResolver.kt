package com.dnschanger.app

import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

class DnsResolver(
    private val upstreams: List<Pair<String, Int>>,
    protectSocket: (DatagramSocket) -> Boolean,
    private val onResponse: (PendingQuery, ByteArray) -> Unit,
    timeoutMs: Int = 2500,
    private val fallbackSecondary: Boolean = true,
    private val onQuery: ((PendingQuery, ByteArray, Int) -> Unit)? = null
) : Runnable {

    data class PendingQuery(
        val id: Int,
        val srcAddr: ByteArray,
        val srcPort: Int,
        val dstAddr: ByteArray,
        val timestamp: Long,
        val query: ByteArray,
        var upstreamIndex: Int = 0,
        var lastSentAt: Long = timestamp
    ) {
        fun key(): String = "$id|${srcPort}|${srcAddr.contentHashCode()}"
    }

    private val perUpstreamTimeout = timeoutMs.coerceIn(500, 10_000).toLong()
    private val totalBudget = (perUpstreamTimeout * (if (fallbackSecondary) maxOf(upstreams.size, 1) else 1) + 2000)
        .coerceAtMost(10_000L)
        .coerceAtLeast(perUpstreamTimeout)

    private val channel: DatagramChannel = DatagramChannel.open().apply { configureBlocking(false) }
    private val selector: Selector = try { Selector.open() } catch (error: Exception) {
        channel.close()
        throw error
    }
    private val pending = ConcurrentHashMap<String, PendingQuery>()
    private val byId = ConcurrentHashMap<Int, ConcurrentLinkedQueue<String>>()

    @Volatile
    private var running = true

    private val thread = Thread(this, "DnsResolver")

    init {
        try {
            if (!protectSocket(channel.socket())) throw VpnFailure("socket_protection_failed")
        } catch (error: Exception) {
            channel.close()
            selector.close()
            throw error
        }
    }

    fun start() {
        channel.register(selector, SelectionKey.OP_READ)
        thread.start()
    }

    fun stop() {
        running = false
        pending.clear()
        byId.clear()
        thread.interrupt()
        try { selector.wakeup() } catch (_: Exception) {}
        try { channel.close() } catch (_: Exception) {}
        try { selector.close() } catch (_: Exception) {}
    }

    fun resolve(query: ByteArray, srcAddr: ByteArray, srcPort: Int, dstAddr: ByteArray) {
        resolve(query, 0, query.size, srcAddr, srcPort, dstAddr)
    }

    fun resolve(query: ByteArray, offset: Int, length: Int, srcAddr: ByteArray, srcPort: Int, dstAddr: ByteArray) {
        if (!running || length < 2 || upstreams.isEmpty() || offset < 0 || offset + length > query.size) return
        val id = ((query[offset].toInt() and 0xFF) shl 8) or (query[offset + 1].toInt() and 0xFF)
        val copy = query.copyOfRange(offset, offset + length)
        val now = System.currentTimeMillis()
        val p = PendingQuery(id, srcAddr, srcPort, dstAddr, now, copy)
        pending[p.key()] = p
        byId.getOrPut(id) { ConcurrentLinkedQueue() }.add(p.key())
        sendTo(p, 0)
    }

    private fun sendTo(p: PendingQuery, index: Int) {
        if (index !in upstreams.indices) return
        p.upstreamIndex = index
        p.lastSentAt = System.currentTimeMillis()
        try {
            val up = upstreams[index]
            channel.send(ByteBuffer.wrap(p.query), InetSocketAddress(up.first, up.second))
        } catch (_: Exception) {
            if (fallbackSecondary && index + 1 < upstreams.size) {
                sendTo(p, index + 1)
            } else {
                removePending(p)
            }
        }
    }

    private fun removePending(p: PendingQuery) {
        pending.remove(p.key())
        byId[p.id]?.remove(p.key())
    }

    private fun takePending(id: Int): PendingQuery? {
        val queue = byId[id] ?: return null
        var key = queue.poll()
        while (key != null) {
            val p = pending.remove(key)
            if (p != null) return p
            key = queue.poll()
        }
        return null
    }

    override fun run() {
        val buf = ByteBuffer.allocate(65535)
        while (running) {
            try {
                val n = selector.select(500)
                if (n > 0) {
                    val it = selector.selectedKeys().iterator()
                    while (it.hasNext()) {
                        val key = it.next()
                        it.remove()
                        if (key.isReadable) {
                            buf.clear()
                            channel.receive(buf)
                            if (buf.position() < 2) continue
                            buf.flip()
                            val response = ByteArray(buf.remaining())
                            buf.get(response)
                            val id = ((response[0].toInt() and 0xFF) shl 8) or (response[1].toInt() and 0xFF)
                            val p = takePending(id) ?: continue
                            try {
                                onResponse(p, response)
                                onQuery?.invoke(p, response, p.upstreamIndex)
                            } catch (_: Exception) {
                            }
                        }
                    }
                }
                val now = System.currentTimeMillis()
                val it = pending.entries.iterator()
                while (it.hasNext()) {
                    val entry = it.next()
                    val p = entry.value
                    if (now - p.timestamp > totalBudget) {
                        it.remove()
                        byId[p.id]?.remove(p.key())
                        continue
                    }
                    if (fallbackSecondary &&
                        p.upstreamIndex + 1 < upstreams.size &&
                        now - p.lastSentAt >= perUpstreamTimeout
                    ) {
                        sendTo(p, p.upstreamIndex + 1)
                    }
                }
            } catch (_: Exception) {
            }
        }
    }
}
