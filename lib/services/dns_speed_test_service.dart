import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/dns_server.dart';

/// Performance and latency testing engine for DNS servers.
class DnsSpeedTestService {
  static final DnsSpeedTestService instance = DnsSpeedTestService();

  final Map<String, int?> _cachedPings = {};
  bool _isTesting = false;

  bool get isTesting => _isTesting;
  Map<String, int?> get cachedPings => Map.unmodifiable(_cachedPings);

  /// DNS Query for `google.com` (Type A, Class IN)
  static Uint8List _buildQueryPacket(int queryId) {
    final builder = BytesBuilder();
    // Header
    builder.addByte((queryId >> 8) & 0xFF);
    builder.addByte(queryId & 0xFF);
    builder.addByte(0x01); // Standard query with RD (recursion desired)
    builder.addByte(0x00);
    builder.addByte(0x00); // QDCOUNT = 1
    builder.addByte(0x01);
    builder.addByte(0x00); // ANCOUNT = 0
    builder.addByte(0x00);
    builder.addByte(0x00); // NSCOUNT = 0
    builder.addByte(0x00);
    builder.addByte(0x00); // ARCOUNT = 0
    builder.addByte(0x00);

    // QNAME: 6google3com0
    final labels = ['google', 'com'];
    for (final label in labels) {
      builder.addByte(label.length);
      builder.add(label.codeUnits);
    }
    builder.addByte(0x00); // end of name

    // QTYPE: A (0x0001)
    builder.addByte(0x00);
    builder.addByte(0x01);

    // QCLASS: IN (0x0001)
    builder.addByte(0x00);
    builder.addByte(0x01);

    return builder.toBytes();
  }

  /// Ping a single DNS server address by performing a real UDP/TCP DNS lookup.
  Future<int?> pingAddress(String address, {int port = 53, Duration timeout = const Duration(milliseconds: 2500)}) async {
    final cleanIp = address.contains(':') && !address.startsWith('[') && address.split(':').length == 2
        ? address.split(':').first
        : address.replaceAll('[', '').replaceAll(']', '');

    final targetPort = address.contains(':') && address.split(':').length == 2
        ? (int.tryParse(address.split(':').last) ?? port)
        : port;

    final ip = InternetAddress.tryParse(cleanIp);
    if (ip == null) return null;

    final stopwatch = Stopwatch()..start();

    // Try UDP DNS lookup first
    try {
      final queryId = Random().nextInt(0xFFFF);
      final packet = _buildQueryPacket(queryId);

      final socket = await RawDatagramSocket.bind(
        ip.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
        0,
      );

      final completer = Completer<int?>();

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null && datagram.data.length >= 2) {
            final respId = (datagram.data[0] << 8) | datagram.data[1];
            if (respId == queryId && !completer.isCompleted) {
              stopwatch.stop();
              completer.complete(stopwatch.elapsedMilliseconds);
            }
          }
        }
      });

      socket.send(packet, ip, targetPort);

      // Set timeout
      Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        try {
          socket.close();
        } catch (_) {}
      });

      final result = await completer.future;
      try {
        socket.close();
      } catch (_) {}

      if (result != null) return result;
    } catch (_) {}

    // Fallback: TCP connect latency test
    try {
      stopwatch.reset();
      stopwatch.start();
      final socket = await Socket.connect(ip, targetPort, timeout: timeout);
      stopwatch.stop();
      await socket.close();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  /// Test a DNS server (tests its primary address, and secondary if primary fails)
  Future<int?> pingServer(DnsServer server, {Duration timeout = const Duration(milliseconds: 2500)}) async {
    if (server.addresses.isEmpty) return null;
    
    // Test primary
    int? ping = await pingAddress(server.addresses.first, timeout: timeout);
    if (ping == null && server.addresses.length > 1) {
      // Test secondary
      ping = await pingAddress(server.addresses[1], timeout: timeout);
    }

    _cachedPings[server.id] = ping;
    return ping;
  }

  /// Test all servers in the list with controlled concurrency
  Future<Map<String, int?>> testAll(
    List<DnsServer> servers, {
    void Function(DnsServer server, int? ping)? onProgress,
    int concurrency = 4,
  }) async {
    _isTesting = true;
    final results = <String, int?>{};

    try {
      for (var i = 0; i < servers.length; i += concurrency) {
        final batch = servers.sublist(i, min(i + concurrency, servers.length));
        final futures = batch.map((server) async {
          final ping = await pingServer(server);
          results[server.id] = ping;
          onProgress?.call(server, ping);
        });
        await Future.wait(futures);
      }
    } finally {
      _isTesting = false;
    }

    return results;
  }

  /// Find the fastest server among the candidates
  Future<DnsServer?> findFastest(List<DnsServer> servers) async {
    if (servers.isEmpty) return null;
    await testAll(servers);

    DnsServer? best;
    int minPing = 999999;

    for (final s in servers) {
      final ping = _cachedPings[s.id];
      if (ping != null && ping > 0 && ping < minPing) {
        minPing = ping;
        best = s.copyWith(pingMs: ping);
      }
    }

    return best ?? servers.first;
  }

  void clearCache() {
    _cachedPings.clear();
  }
}
