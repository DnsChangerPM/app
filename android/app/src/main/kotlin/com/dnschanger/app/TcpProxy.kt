package com.dnschanger.app

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random

/**
 * Minimal TCP proxy for TCP DNS (port 53). Terminates the client TCP session,
 * forwards the DNS query over a fresh TCP connection to the upstream resolver and
 * writes the answer back using a tiny TCP state machine.
 */
class TcpProxy(
    private val srcAddr: ByteArray,
    private val srcPort: Int,
    private val dstAddr: ByteArray,
    private val upstreams: List<Pair<String, Int>>,
    private val protectSocket: (Socket) -> Boolean,
    private val write: (ByteArray) -> Unit,
    private val onClose: (TcpProxy) -> Unit,
    private val fallbackSecondary: Boolean = true,
    private val onQuery: ((ByteArray, Int, Long) -> Unit)? = null
) {
    companion object {
        private const val TAG = "TcpProxy"
        const val FIN = 0x01
        const val SYN = 0x02
        const val RST = 0x04
        const val PSH = 0x08
        const val ACK = 0x10
        private const val MAX_SEGMENT = 1440
    }

    private enum class State { NEW, SYN_RECEIVED, ESTABLISHED, CLOSED }

    @Volatile private var state = State.NEW
    @Volatile private var clientNextSeq = 0
    @Volatile private var serverSeq = Random.nextInt(0, Int.MAX_VALUE)
    private val reassembly = ByteArrayOutputStream()

    private val socketLock = Any()
    private var socket: Socket? = null
    @Volatile private var upstreamOut: OutputStream? = null
    private var upstreamThread: Thread? = null
    private val lastActive = AtomicLong(0)
    private val closed = AtomicBoolean(false)

    fun isIdle(ms: Long): Boolean = System.currentTimeMillis() - lastActive.get() > ms

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        state = State.CLOSED
        upstreamThread?.interrupt()
        val closing = synchronized(socketLock) {
            val current = socket
            socket = null
            current
        }
        // Do not wait for handleData's monitor while a peer stalls a write.
        try { closing?.close() } catch (_: Exception) { }
    }

    @Synchronized
    fun feed(segment: ByteArray, offset: Int, length: Int, flags: Int) {
        if (closed.get()) return
        lastActive.set(System.currentTimeMillis())
        if (length < offset + 20) return

        val seq = readInt(segment, offset + 4)
        val dataOffset = ((segment[offset + 12].toInt() shr 4) and 0xF) * 4
        val payloadStart = offset + dataOffset
        val payloadLen = if (length > payloadStart) length - payloadStart else 0

        when {
            (flags and RST) != 0 -> {
                state = State.CLOSED
                onClose(this)
            }
            (flags and SYN) != 0 && state == State.NEW -> {
                clientNextSeq = seq + 1
                serverSeq = Random.nextInt(0, Int.MAX_VALUE)
                val synAckSeq = serverSeq
                sendSegment(SYN or ACK, synAckSeq, clientNextSeq, ByteArray(0))
                serverSeq = synAckSeq + 1
                state = State.SYN_RECEIVED
            }
            state == State.SYN_RECEIVED && (flags and ACK) != 0 -> {
                if (readInt(segment, offset + 8) == serverSeq) {
                    state = State.ESTABLISHED
                    connectUpstream()
                    if (payloadLen > 0) {
                        acceptData(segment, payloadStart, payloadLen, seq)
                    }
                }
            }
            state == State.ESTABLISHED -> {
                if (payloadLen > 0) {
                    acceptData(segment, payloadStart, payloadLen, seq)
                }
                if ((flags and FIN) != 0) {
                    clientNextSeq += 1
                    sendSegment(FIN or ACK, serverSeq, clientNextSeq, ByteArray(0))
                    serverSeq += 1
                    state = State.CLOSED
                    onClose(this)
                }
            }
        }
    }

    private fun acceptData(segment: ByteArray, payloadStart: Int, payloadLen: Int, seq: Int) {
        if (seq == clientNextSeq) {
            clientNextSeq += payloadLen
            val payload = segment.copyOfRange(payloadStart, payloadStart + payloadLen)
            handleData(payload)
            sendSegment(ACK, serverSeq, clientNextSeq, ByteArray(0))
        } else {
            sendSegment(ACK, serverSeq, clientNextSeq, ByteArray(0))
        }
    }

    @Synchronized
    private fun handleData(payload: ByteArray) {
        if (closed.get()) return
        reassembly.write(payload)
        val buf = reassembly.toByteArray()
        var pos = 0
        val out = upstreamOut
        if (out != null) {
            while (buf.size - pos >= 2) {
                val qLen = ((buf[pos].toInt() and 0xFF) shl 8) or (buf[pos + 1].toInt() and 0xFF)
                if (buf.size - pos - 2 < qLen) break
                try {
                    out.write(buf, pos, 2 + qLen)
                    pos += 2 + qLen
                } catch (e: Exception) {
                    onClose(this)
                    return
                }
            }
            try {
                out.flush()
            } catch (_: Exception) {
            }
            if (pos == buf.size) {
                reassembly.reset()
            } else {
                reassembly.reset()
                reassembly.write(buf, pos, buf.size - pos)
            }
        }
    }

    private fun connectUpstream() {
        upstreamThread = Thread(upstream@{
            val candidates = if (fallbackSecondary) upstreams else upstreams.take(1)
            var answered = false
            for ((index, upstream) in candidates.withIndex()) {
                if (closed.get()) return@upstream
                try {
                    val s = Socket()
                    synchronized(socketLock) {
                        if (closed.get()) { s.close(); return@upstream }
                        socket = s
                    }
                    if (!protectSocket(s)) throw IOException("DNS socket protection failed")
                    s.connect(InetSocketAddress(upstream.first, upstream.second), 10_000)
                    if (closed.get()) return@upstream
                    synchronized(this) {
                        upstreamOut = BufferedOutputStream(s.getOutputStream())
                    }
                    val pending = synchronized(this) {
                        val b = reassembly.toByteArray()
                        reassembly.reset()
                        b
                    }
                    if (pending.isNotEmpty()) {
                        handleData(pending)
                    }
                    val input: InputStream = BufferedInputStream(s.getInputStream())
                    val lenBuf = ByteArray(2)
                    val started = System.currentTimeMillis()
                    while (!closed.get()) {
                        var headerRead = 0
                        while (headerRead < 2) {
                            val count = input.read(lenBuf, headerRead, 2 - headerRead)
                            if (count < 0) break
                            headerRead += count
                        }
                        if (headerRead != 2) break
                        val respLen = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
                        val response = ByteArray(respLen)
                        var read = 0
                        while (read < respLen) {
                            val n = input.read(response, read, respLen - read)
                            if (n < 0) break
                            read += n
                        }
                        if (read < respLen) break
                        answered = true
                        sendDnsResponse(response)
                        onQuery?.invoke(response, index, System.currentTimeMillis() - started)
                    }
                    if (answered) break
                } catch (e: Exception) {
                    if (!closed.get()) Log.w(TAG, "upstream DNS connection failed")
                } finally {
                    synchronized(this) { upstreamOut = null }
                    val closing = synchronized(socketLock) {
                        val current = socket
                        socket = null
                        current
                    }
                    try { closing?.close() } catch (_: Exception) {}
                }
                if (answered) break
            }
            if (!closed.get()) onClose(this)
        }, "TcpProxy-upstream")
        upstreamThread!!.start()
    }

    @Synchronized
    private fun sendDnsResponse(response: ByteArray) {
        val framed = ByteArray(response.size + 2)
        framed[0] = ((response.size shr 8) and 0xFF).toByte()
        framed[1] = (response.size and 0xFF).toByte()
        System.arraycopy(response, 0, framed, 2, response.size)
        var offset = 0
        while (offset < framed.size) {
            val end = minOf(offset + MAX_SEGMENT, framed.size)
            val slice = framed.copyOfRange(offset, end)
            val flags = if (end == framed.size) PSH or ACK else ACK
            val seq = serverSeq
            sendSegment(flags, seq, clientNextSeq, slice)
            serverSeq = seq + slice.size
            offset = end
        }
    }

    private fun sendSegment(flags: Int, seq: Int, ack: Int, payload: ByteArray) {
        if (closed.get()) return
        val pkt = PacketUtils.buildTcpResponse(dstAddr, srcAddr, 53, srcPort, seq, ack, flags, payload)
        try {
            write(pkt)
        } catch (_: Exception) {
        }
    }

    private fun readInt(data: ByteArray, offset: Int): Int {
        return ((data[offset].toInt() and 0xFF) shl 24) or
            ((data[offset + 1].toInt() and 0xFF) shl 16) or
            ((data[offset + 2].toInt() and 0xFF) shl 8) or
            (data[offset + 3].toInt() and 0xFF)
    }
}
