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

  static Uint8List buildQueryPacket(String host, {int queryId = 0, int qtype = 1}) {
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

    final labels = host.split('.').where((l) => l.isNotEmpty);
    for (final label in labels) {
      builder.addByte(label.length);
      builder.add(label.codeUnits);
    }
    builder.addByte(0x00); // end of name

    builder.addByte((qtype >> 8) & 0xFF);
    builder.addByte(qtype & 0xFF);

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
      final packet = buildQueryPacket('google.com', queryId: queryId);

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
      if (ping != null && ping >= 0 && ping < minPing) {
        minPing = ping;
        best = s.copyWith(pingMs: ping);
      }
    }

    return best ?? servers.first;
  }

  void clearCache() {
    _cachedPings.clear();
  }

  /// Direct A+AAAA lookup against [server] (UDP then TCP), bypassing the system resolver.
  Future<({List<String> ips, int latencyMs, String serverName})?> lookupHost(
    String host,
    DnsServer server, {
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    if (server.addresses.isEmpty) return null;
    final stopwatch = Stopwatch()..start();
    for (final address in server.addresses) {
      final a = await _queryType(host, address, 1, timeout);
      final aaaa = await _queryType(host, address, 28, timeout);
      final ips = [...?a, ...?aaaa];
      if (ips.isNotEmpty) {
        stopwatch.stop();
        return (ips: ips, latencyMs: stopwatch.elapsedMilliseconds, serverName: server.name);
      }
    }
    return null;
  }

  Future<List<String>?> _queryType(String host, String address, int qtype, Duration timeout) async {
    final cleanIp = address.contains(':') && !address.startsWith('[') && address.split(':').length == 2
        ? address.split(':').first
        : address.replaceAll('[', '').replaceAll(']', '');
    final targetPort = address.contains(':') && address.split(':').length == 2
        ? (int.tryParse(address.split(':').last) ?? 53)
        : 53;
    final ip = InternetAddress.tryParse(cleanIp);
    if (ip == null) return null;
    final queryId = Random().nextInt(0xFFFF);
    final packet = buildQueryPacket(host, queryId: queryId, qtype: qtype);
    try {
      final socket = await RawDatagramSocket.bind(
        ip.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
        0,
      );
      final completer = Completer<List<String>?>();
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null && datagram.data.length >= 12) {
            final respId = (datagram.data[0] << 8) | datagram.data[1];
            if (respId == queryId && !completer.isCompleted) {
              completer.complete(_parseIps(datagram.data, qtype));
            }
          }
        }
      });
      socket.send(packet, ip, targetPort);
      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
        try { socket.close(); } catch (_) {}
      });
      final result = await completer.future;
      try { socket.close(); } catch (_) {}
      if (result != null && result.isNotEmpty) return result;
    } catch (_) {}
    try {
      final sock = await Socket.connect(ip, targetPort, timeout: timeout);
      final framed = Uint8List(packet.length + 2);
      framed[0] = (packet.length >> 8) & 0xFF;
      framed[1] = packet.length & 0xFF;
      framed.setRange(2, framed.length, packet);
      sock.add(framed);
      final chunks = <int>[];
      await for (final data in sock.timeout(timeout, onTimeout: (s) { s.close(); })) {
        chunks.addAll(data);
        if (chunks.length >= 2) {
          final len = (chunks[0] << 8) | chunks[1];
          if (chunks.length >= 2 + len) {
            await sock.close();
            return _parseIps(Uint8List.fromList(chunks.sublist(2, 2 + len)), qtype);
          }
        }
      }
      await sock.close();
    } catch (_) {}
    return null;
  }

  List<String> _parseIps(List<int> msg, int wantType) {
    if (msg.length < 12) return [];
    final ancount = (msg[6] << 8) | msg[7];
    var pos = 12;
    void skipName() {
      var jumps = 0;
      while (pos < msg.length) {
        final len = msg[pos];
        if (len == 0) { pos++; return; }
        if ((len & 0xC0) == 0xC0) { pos += 2; return; }
        pos += 1 + len;
        if (++jumps > 20) return;
      }
    }
    skipName();
    pos += 4;
    final ips = <String>[];
    for (var i = 0; i < ancount && pos + 10 <= msg.length; i++) {
      skipName();
      if (pos + 10 > msg.length) break;
      final type = (msg[pos] << 8) | msg[pos + 1];
      final rdlen = (msg[pos + 8] << 8) | msg[pos + 9];
      pos += 10;
      if (pos + rdlen > msg.length) break;
      if (type == wantType) {
        if (type == 1 && rdlen == 4) {
          ips.add('${msg[pos]}.${msg[pos + 1]}.${msg[pos + 2]}.${msg[pos + 3]}');
        } else if (type == 28 && rdlen == 16) {
          final b = msg.sublist(pos, pos + 16);
          final parts = <String>[];
          for (var j = 0; j < 16; j += 2) {
            parts.add(((b[j] << 8) | b[j + 1]).toRadixString(16));
          }
          ips.add(parts.join(':'));
        }
      }
      pos += rdlen;
    }
    return ips;
  }
}
