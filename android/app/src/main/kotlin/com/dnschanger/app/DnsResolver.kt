package com.dnschanger.app

import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class DnsResolver(
    private val upstreams: List<Pair<String, Int>>,
    private val onResponse: (PendingQuery, ByteArray) -> Unit
) : Runnable {

    data class PendingQuery(
        val id: Int,
        val srcAddr: ByteArray,
        val srcPort: Int,
        val dstAddr: ByteArray,
        val timestamp: Long
    )

    private val channel: DatagramChannel = DatagramChannel.open().apply { configureBlocking(false) }
    private val selector: Selector = Selector.open()
    private val pending = ConcurrentHashMap<Int, PendingQuery>()
    private val idx = AtomicInteger(0)

    @Volatile
    private var running = true

    private val thread = Thread(this, "DnsResolver")
    private val sendBuffer = ByteBuffer.allocate(4096)

    fun start() {
        channel.register(selector, SelectionKey.OP_READ)
        thread.start()
    }

    fun stop() {
        running = false
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
        if (query.size < 2) return
        val id = ((query[0].toInt() and 0xFF) shl 8) or (query[1].toInt() and 0xFF)
        if (upstreams.isEmpty()) return
        val upstream = upstreams[idx.getAndIncrement() % upstreams.size]
        pending[id] = PendingQuery(id, srcAddr, srcPort, dstAddr, System.currentTimeMillis())
        sendBuffer.clear()
        sendBuffer.put(query)
        sendBuffer.flip()
        try {
            channel.send(sendBuffer, InetSocketAddress(upstream.first, upstream.second))
        } catch (e: Exception) {
            pending.remove(id)
        }
    }

    override fun run() {
        val buf = ByteBuffer.allocate(4096)
        while (running) {
            try {
                val n = selector.select(1000)
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
                val now = System.currentTimeMillis()
                val it = pending.entries.iterator()
                while (it.hasNext()) {
                    if (now - it.next().value.timestamp > 20_000) it.remove()
                }
            } catch (_: Exception) {
                // keep looping
            }
        }
    }
}
