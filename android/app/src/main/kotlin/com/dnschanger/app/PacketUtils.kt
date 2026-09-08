package com.dnschanger.app

import java.nio.ByteBuffer

object PacketUtils {

    const val PROTO_TCP = 6
    const val PROTO_UDP = 17

    data class Parsed(
        val protocol: Int,
        val isIpv6: Boolean,
        val srcAddr: ByteArray,
        val dstAddr: ByteArray,
        val srcPort: Int,
        val dstPort: Int,
        /** Offset of the TCP/UDP header inside the packet. */
        val transportOffset: Int,
        val tcpFlags: Int
    )

    fun parse(packet: ByteArray, length: Int): Parsed? {
        if (length < 20) return null
        val version = (packet[0].toInt() shr 4) and 0xF
        if (version == 4) {
            val ihl = (packet[0].toInt() and 0xF) * 4
            if (length < ihl + 8) return null
            val protocol = packet[9].toInt() and 0xFF
            val src = packet.copyOfRange(12, 16)
            val dst = packet.copyOfRange(16, 20)
            val srcPort = ((packet[ihl].toInt() and 0xFF) shl 8) or (packet[ihl + 1].toInt() and 0xFF)
            val dstPort = ((packet[ihl + 2].toInt() and 0xFF) shl 8) or (packet[ihl + 3].toInt() and 0xFF)
            var flags = 0
            if (protocol == PROTO_TCP && length >= ihl + 14) {
                flags = packet[ihl + 13].toInt() and 0xFF
            }
            return Parsed(protocol, false, src, dst, srcPort, dstPort, ihl, flags)
        } else if (version == 6) {
            if (length < 40 + 8) return null
            val nextHeader = packet[6].toInt() and 0xFF
            val src = packet.copyOfRange(8, 24)
            val dst = packet.copyOfRange(24, 40)
            val srcPort = ((packet[40].toInt() and 0xFF) shl 8) or (packet[41].toInt() and 0xFF)
            val dstPort = ((packet[42].toInt() and 0xFF) shl 8) or (packet[43].toInt() and 0xFF)
            var flags = 0
            if (nextHeader == PROTO_TCP && length >= 54) {
                flags = packet[53].toInt() and 0xFF
            }
            return Parsed(nextHeader, true, src, dst, srcPort, dstPort, 40, flags)
        }
        return null
    }

    /** Build a UDP packet (with IP header) from srcAddr->dstAddr carrying [payload]. */
    fun buildUdpResponse(
        srcAddr: ByteArray,
        dstAddr: ByteArray,
        srcPort: Int,
        dstPort: Int,
        payload: ByteArray
    ): ByteArray {
        return if (srcAddr.size == 16) {
            buildUdp6(srcAddr, dstAddr, srcPort, dstPort, payload)
        } else {
            buildUdp4(srcAddr, dstAddr, srcPort, dstPort, payload)
        }
    }

    private fun buildUdp4(src: ByteArray, dst: ByteArray, srcPort: Int, dstPort: Int, payload: ByteArray): ByteArray {
        val total = 20 + 8 + payload.size
        val buf = ByteBuffer.allocate(total)
        // IP header
        buf.put((0x45).toByte()) // v4, IHL 5
        buf.put(0)
        buf.putShort(total.toShort())
        buf.putShort(0) // id
        buf.putShort(0) // flags/fragment
        buf.put(64) // TTL
        buf.put(PROTO_UDP.toByte())
        buf.putShort(0) // checksum placeholder
        buf.put(src)
        buf.put(dst)
        // compute IP checksum
        val ipChecksum = checksum(buf.array(), 0, 20)
        buf.putShort(10, ipChecksum.toShort())
        // UDP header
        buf.putShort(srcPort.toShort())
        buf.putShort(dstPort.toShort())
        buf.putShort((8 + payload.size).toShort())
        buf.putShort(0) // udp checksum placeholder
        buf.put(payload)
        // UDP checksum with pseudo header
        val udpOffset = 20
        val pseudo = ByteBuffer.allocate(12)
        pseudo.put(src)
        pseudo.put(dst)
        pseudo.put(0)
        pseudo.put(PROTO_UDP.toByte())
        pseudo.putShort((8 + payload.size).toShort())
        val udpData = ByteArray(8 + payload.size)
        System.arraycopy(buf.array(), udpOffset, udpData, 0, udpData.size)
        val udpChecksum = checksumConcat(pseudo.array(), udpData)
        if (udpChecksum == 0) {
            buf.putShort(udpOffset + 6, 0xFFFF.toShort())
        } else {
            buf.putShort(udpOffset + 6, udpChecksum.toShort())
        }
        return buf.array()
    }

    private fun buildUdp6(src: ByteArray, dst: ByteArray, srcPort: Int, dstPort: Int, payload: ByteArray): ByteArray {
        val total = 40 + 8 + payload.size
        val buf = ByteBuffer.allocate(total)
        // IPv6 header
        buf.put((0x60).toByte()) // version 6
        buf.put(0)
        buf.put(0)
        buf.putShort((8 + payload.size).toShort()) // payload length
        buf.put(PROTO_UDP.toByte())
        buf.put(64) // hop limit
        buf.put(src)
        buf.put(dst)
        // UDP header
        buf.putShort(srcPort.toShort())
        buf.putShort(dstPort.toShort())
        buf.putShort((8 + payload.size).toShort())
        buf.putShort(0)
        buf.put(payload)
        // UDP checksum with IPv6 pseudo header
        val pseudo = ByteBuffer.allocate(40)
        pseudo.put(src)
        pseudo.put(dst)
        pseudo.putInt(8 + payload.size)
        pseudo.putInt(PROTO_UDP)
        val udpData = ByteArray(8 + payload.size)
        System.arraycopy(buf.array(), 40, udpData, 0, udpData.size)
        val udpChecksum = checksumConcat(pseudo.array(), udpData)
        if (udpChecksum == 0) {
            buf.putShort(40 + 6, 0xFFFF.toShort())
        } else {
            buf.putShort(40 + 6, udpChecksum.toShort())
        }
        return buf.array()
    }

    /** Build a TCP packet from srcAddr->dstAddr with the given TCP header fields. */
    fun buildTcpResponse(
        srcAddr: ByteArray,
        dstAddr: ByteArray,
        srcPort: Int,
        dstPort: Int,
        seq: Int,
        ack: Int,
        flags: Int,
        payload: ByteArray
    ): ByteArray {
        val tcpLen = 20 + payload.size
        val tcp = ByteBuffer.allocate(tcpLen)
        tcp.putShort(srcPort.toShort())
        tcp.putShort(dstPort.toShort())
        tcp.putInt(seq)
        tcp.putInt(ack)
        tcp.put((0x50).toByte()) // data offset 5 (20 bytes)
        tcp.put(flags.toByte())
        tcp.putShort(65535) // window
        tcp.putShort(0) // checksum placeholder
        tcp.putShort(0) // urgent pointer
        tcp.put(payload)
        val tcpArr = tcp.array()

        if (srcAddr.size == 16) {
            val pseudo = ByteBuffer.allocate(40)
            pseudo.put(srcAddr)
            pseudo.put(dstAddr)
            pseudo.putInt(tcpLen)
            pseudo.putInt(PROTO_TCP)
            val c = checksumConcat(pseudo.array(), tcpArr)
            tcpArr[16] = ((c shr 8) and 0xFF).toByte()
            tcpArr[17] = (c and 0xFF).toByte()

            val total = 40 + tcpLen
            val buf = ByteBuffer.allocate(total)
            buf.put((0x60).toByte())
            buf.put(0)
            buf.put(0)
            buf.putShort(tcpLen.toShort())
            buf.put(PROTO_TCP.toByte())
            buf.put(64)
            buf.put(srcAddr)
            buf.put(dstAddr)
            buf.put(tcpArr)
            return buf.array()
        } else {
            val pseudo = ByteBuffer.allocate(12)
            pseudo.put(srcAddr)
            pseudo.put(dstAddr)
            pseudo.put(0)
            pseudo.put(PROTO_TCP.toByte())
            pseudo.putShort(tcpLen.toShort())
            val c = checksumConcat(pseudo.array(), tcpArr)
            tcpArr[16] = ((c shr 8) and 0xFF).toByte()
            tcpArr[17] = (c and 0xFF).toByte()

            val total = 20 + tcpLen
            val buf = ByteBuffer.allocate(total)
            buf.put((0x45).toByte())
            buf.put(0)
            buf.putShort(total.toShort())
            buf.putShort(0)
            buf.putShort(0)
            buf.put(64)
            buf.put(PROTO_TCP.toByte())
            buf.putShort(0)
            buf.put(srcAddr)
            buf.put(dstAddr)
            val ipc = checksum(buf.array(), 0, 20)
            buf.putShort(10, ipc.toShort())
            buf.put(tcpArr)
            return buf.array()
        }
    }

    fun checksum(data: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var i = offset
        val end = offset + length
        while (i < end - 1) {
            sum += (((data[i].toInt() and 0xFF) shl 8) or (data[i + 1].toInt() and 0xFF)).toLong()
            i += 2
        }
        if (i == end - 1) {
            sum += ((data[i].toInt() and 0xFF) shl 8).toLong()
        }
        while ((sum shr 16) != 0L) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        return (sum.toInt() and 0xFFFF).inv() and 0xFFFF
    }

    private fun checksumConcat(first: ByteArray, second: ByteArray): Int {
        var sum = 0L
        var i = 0
        while (i < first.size - 1) {
            sum += (((first[i].toInt() and 0xFF) shl 8) or (first[i + 1].toInt() and 0xFF)).toLong()
            i += 2
        }
        if (i == first.size - 1) {
            sum += ((first[i].toInt() and 0xFF) shl 8).toLong()
        }
        i = 0
        while (i < second.size - 1) {
            sum += (((second[i].toInt() and 0xFF) shl 8) or (second[i + 1].toInt() and 0xFF)).toLong()
            i += 2
        }
        if (i == second.size - 1) {
            sum += ((second[i].toInt() and 0xFF) shl 8).toLong()
        }
        while ((sum shr 16) != 0L) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        return (sum.toInt() and 0xFFFF).inv() and 0xFFFF
    }

    fun intToBytes(value: Int): ByteArray {
        return byteArrayOf(
            ((value shr 24) and 0xFF).toByte(),
            ((value shr 16) and 0xFF).toByte(),
            ((value shr 8) and 0xFF).toByte(),
            (value and 0xFF).toByte()
        )
    }
}
