package com.dnschanger.app

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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
    private val write: (ByteArray) -> Unit,
    private val onClose: (TcpProxy) -> Unit
) {
    companion object {
        private const val TAG = "TcpProxy"
        const val FIN = 0x01
        const val SYN = 0x02
        const val RST = 0x04
        const val PSH = 0x08
        const val ACK = 0x10
    }

    private enum class State { NEW, SYN_RECEIVED, ESTABLISHED, CLOSED }

    private var state = State.NEW
    private var clientNextSeq = 0
    private var serverSeq = Random.nextInt(0, Int.MAX_VALUE)
    private val reassembly = ByteArrayOutputStream()

    private var socket: Socket? = null
    private var upstreamOut: OutputStream? = null
    private var upstreamThread: Thread? = null
    private val lastActive = AtomicInteger(0)
    private val closed = AtomicBoolean(false)

    fun isIdle(ms: Long): Boolean = System.currentTimeMillis() - lastActive.get() > ms

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        state = State.CLOSED
        try {
            socket?.close()
        } catch (_: Exception) {
        }
    }

    fun feed(segment: ByteArray, offset: Int, length: Int, flags: Int) {
        if (closed.get()) return
        lastActive.set(System.currentTimeMillis().toInt())
        if (length < offset + 20) return

        val seq = readInt(segment, offset + 4)
        val ack = readInt(segment, offset + 8)
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
                sendSegment(SYN or ACK, serverSeq, clientNextSeq, ByteArray(0))
                serverSeq += 1
                state = State.SYN_RECEIVED
            }
            state == State.SYN_RECEIVED && (flags and ACK) != 0 -> {
                if (ack == serverSeq) {
                    state = State.ESTABLISHED
                    connectUpstream()
                    if (payloadLen > 0) {
                        acceptData(segment, payloadStart, payloadLen, seq, flags)
                    }
                }
            }
            state == State.ESTABLISHED -> {
                if (payloadLen > 0) {
                    acceptData(segment, payloadStart, payloadLen, seq, flags)
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

    private fun acceptData(segment: ByteArray, payloadStart: Int, payloadLen: Int, seq: Int, flags: Int) {
        if (seq == clientNextSeq) {
            clientNextSeq += payloadLen
            val payload = segment.copyOfRange(payloadStart, payloadStart + payloadLen)
            handleData(payload)
            // Acknowledge received data.
            sendSegment(ACK, serverSeq, clientNextSeq, ByteArray(0))
        } else {
            // Out-of-order or retransmission: re-ack our position.
            sendSegment(ACK, serverSeq, clientNextSeq, ByteArray(0))
        }
    }

    @Synchronized
    private fun handleData(payload: ByteArray) {
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
        val upstream = upstreams.firstOrNull() ?: return
        upstreamThread = Thread({
            try {
                val s = Socket()
                s.connect(InetSocketAddress(upstream.first, upstream.second), 10_000)
                socket = s
                upstreamOut = BufferedOutputStream(s.getOutputStream())
                // Forward anything the client sent while we were connecting.
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
                while (!closed.get()) {
                    if (input.read(lenBuf) != 2) break
                    val respLen = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
                    val response = ByteArray(respLen)
                    var read = 0
                    while (read < respLen) {
                        val n = input.read(response, read, respLen - read)
                        if (n < 0) break
                        read += n
                    }
                    if (read < respLen) break
                    sendDnsResponse(response)
                }
            } catch (e: Exception) {
                Log.w(TAG, "upstream error", e)
            } finally {
                if (!closed.get()) onClose(this)
            }
        }, "TcpProxy-upstream")
        upstreamThread!!.start()
    }

    private fun sendDnsResponse(response: ByteArray) {
        val framed = ByteArray(response.size + 2)
        framed[0] = ((response.size shr 8) and 0xFF).toByte()
        framed[1] = (response.size and 0xFF).toByte()
        System.arraycopy(response, 0, framed, 2, response.size)
        sendSegment(PSH or ACK, serverSeq, clientNextSeq, framed)
        serverSeq += framed.size
    }

    private fun sendSegment(flags: Int, seq: Int, ack: Int, payload: ByteArray) {
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
