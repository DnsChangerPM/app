package com.dnschanger.app

import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class DnsResolver(
    private val upstreams: List<Pair<String, Int>>,
    protectSocket: (DatagramSocket) -> Boolean,
    private val onResponse: (PendingQuery, ByteArray) -> Unit
) : Runnable {

    data class PendingQuery(
        val id: Int,
        val srcAddr: ByteArray,
        val srcPort: Int,
        val dstAddr: ByteArray,
        val timestamp: Long,
        var secondarySent: Boolean = false
    )

    private val channel: DatagramChannel = DatagramChannel.open().apply { configureBlocking(false) }
    private val selector: Selector = try { Selector.open() } catch (error: Exception) {
        channel.close()
        throw error
    }
    private val pending = ConcurrentHashMap<Int, PendingQuery>()
    private val idx = AtomicInteger(0)

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
        thread.interrupt()
        try {
            selector.wakeup()
        } catch (_: Exception) {
        }
        try {
            channel.close()
        } catch (_: Exception) {
        }
        try {
            selector.close()
        } catch (_: Exception) {
        }
    }

    fun resolve(query: ByteArray, srcAddr: ByteArray, srcPort: Int, dstAddr: ByteArray) {
        if (!running || query.size < 2 || upstreams.isEmpty()) return
        val id = ((query[0].toInt() and 0xFF) shl 8) or (query[1].toInt() and 0xFF)
        val upstream = upstreams[0] // Prefer primary upstream first for speed
        pending[id] = PendingQuery(id, srcAddr, srcPort, dstAddr, System.currentTimeMillis())
        try {
            channel.send(ByteBuffer.wrap(query), InetSocketAddress(upstream.first, upstream.second))
        } catch (e: Exception) {
            if (upstreams.size > 1) {
                try {
                    val sec = upstreams[1]
                    channel.send(ByteBuffer.wrap(query), InetSocketAddress(sec.first, sec.second))
                } catch (_: Exception) {
                    pending.remove(id)
                }
            } else {
                pending.remove(id)
            }
        }
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
                            val p = pending.remove(id) ?: continue
                            try {
                                onResponse(p, response)
                            } catch (_: Exception) {
                            }
                        }
                    }
                }
                // Cleanup stale queries older than 10 seconds
                val now = System.currentTimeMillis()
                val it = pending.entries.iterator()
                while (it.hasNext()) {
                    val entry = it.next()
                    if (now - entry.value.timestamp > 10_000) {
                        it.remove()
                    }
                }
            } catch (_: Exception) {
                // keep looping
            }
        }
    }
}
