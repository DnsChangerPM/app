import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dns_server.dart';
import '../services/dns_catalog.dart';
import '../services/dns_speed_test_service.dart';
import '../services/custom_dns_service.dart';
import '../services/license_service.dart';

class SpeedTestScreen extends StatefulWidget {
  final Function(DnsServer server)? onSelectAndConnect;
  final String? currentSelectedId;

  const SpeedTestScreen({
    super.key,
    this.onSelectAndConnect,
    this.currentSelectedId,
  });

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  final DnsSpeedTestService _speedTest = DnsSpeedTestService.instance;
  final CustomDnsService _customDns = CustomDnsService();
  final LicenseService _license = LicenseService();

  List<DnsServer> _servers = [];
  Map<String, int?> _pings = {};
  bool _testing = false;
  double _progress = 0;
  DnsCategory _selectedCategory = DnsCategory.all;
  String _searchQuery = '';
  String? _fastestId;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    final custom = await _customDns.load();
    await _license.load();
    final license = _license.cachedInfo;

    final all = <DnsServer>[...custom, ...freeDnsServers];
    if (license != null && license.isActive && license.dnsServers.isNotEmpty) {
      all.add(DnsServer(
        id: 'license_0',
        name: 'Subscription DNS',
        description: 'Private subscription server',
        addresses: license.dnsServers,
        isPremium: true,
        category: DnsCategory.general,
      ));
    }

    if (mounted) {
      setState(() {
        _servers = all;
        _pings = Map.from(_speedTest.cachedPings);
      });
    }
  }

  Future<void> _startTestAll() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _progress = 0;
    });

    final targetList = _filteredServers;
    int completed = 0;

    await _speedTest.testAll(
      targetList,
      onProgress: (server, ping) {
        if (mounted) {
          setState(() {
            _pings[server.id] = ping;
            completed++;
            _progress = completed / targetList.length;
          });
        }
      },
    );

    // Find fastest
    int minPing = 999999;
    String? bestId;
    for (final s in targetList) {
      final p = _pings[s.id];
      if (p != null && p > 0 && p < minPing) {
        minPing = p;
        bestId = s.id;
      }
    }

    if (mounted) {
      setState(() {
        _testing = false;
        _fastestId = bestId;
      });
    }
  }

  List<DnsServer> get _filteredServers {
    return _servers.where((s) {
      if (_selectedCategory != DnsCategory.all && s.category != _selectedCategory) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final matchName = s.name.toLowerCase().contains(query);
        final matchDesc = s.description.toLowerCase().contains(query);
        final matchIp = s.addresses.any((a) => a.contains(query));
        if (!matchName && !matchDesc && !matchIp) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final pingA = _pings[a.id];
        final pingB = _pings[b.id];
        if (pingA != null && pingB != null) return pingA.compareTo(pingB);
        if (pingA != null) return -1;
        if (pingB != null) return 1;
        return 0;
      });
  }

  Color _pingColor(int? ping) {
    if (ping == null) return Colors.white38;
    if (ping < 60) return const Color(0xFF00D1B2);
    if (ping < 130) return const Color(0xFF3AA6FF);
    if (ping < 250) return const Color(0xFFFFC107);
    return const Color(0xFFFF5C5C);
  }

  String _pingText(int? ping) {
    if (ping == null) return 'تست نشده';
    if (ping <= 0) return 'خطا / ناموفق';
    return '$ping میلی‌ثانیه';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredServers;
    final fastest = _fastestId != null
        ? _servers.cast<DnsServer?>().firstWhere((s) => s?.id == _fastestId, orElse: () => null)
        : null;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تست پینگ و سرعت DNS'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'تست مجدد',
              onPressed: _testing ? null : _startTestAll,
            ),
          ],
        ),
        body: Column(
          children: [
            // Top action banner
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111B2E),
                border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.06))),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _testing ? null : _startTestAll,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF3AA6FF),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: _testing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.speed),
                          label: Text(_testing ? 'در حال تست سرورها…' : 'شروع تست تمام سرورها'),
                        ),
                      ),
                      if (fastest != null) ...[
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF00D1B2),
                            side: const BorderSide(color: Color(0xFF00D1B2)),
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                          ),
                          onPressed: () {
                            widget.onSelectAndConnect?.call(fastest);
                            Navigator.pop(context, fastest);
                          },
                          icon: const Icon(Icons.bolt),
                          label: const Text('انتخاب سریع‌ترین'),
                        ),
                      ],
                    ],
                  ),
                  if (_testing) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF00D1B2)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ],
              ),
            ),

            // Search and Category filter
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                decoration: InputDecoration(
                  hintText: 'جستجوی نام یا آدرس DNS…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF111B2E),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: DnsCategory.values.map((cat) {
                  final isSel = _selectedCategory == cat;
                  return Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: FilterChip(
                      selected: isSel,
                      label: Text(cat.labelFa),
                      onSelected: (_) => setState(() => _selectedCategory = cat),
                      backgroundColor: const Color(0xFF111B2E),
                      selectedColor: const Color(0xFF3AA6FF).withOpacity(0.25),
                      checkmarkColor: const Color(0xFF3AA6FF),
                    ),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 8),

            // Server list with pings
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final server = filtered[index];
                  final ping = _pings[server.id];
                  final isFastest = server.id == _fastestId;
                  final isCurrent = server.id == widget.currentSelectedId;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    color: isCurrent
                        ? const Color(0xFF13263F)
                        : const Color(0xFF111B2E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: isFastest
                          ? const BorderSide(color: Color(0xFF00D1B2), width: 1.5)
                          : isCurrent
                              ? const BorderSide(color: Color(0xFF3AA6FF), width: 1.5)
                              : BorderSide(color: Colors.white.withOpacity(0.06)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: isFastest
                                  ? const Color(0xFF00D1B2).withOpacity(0.15)
                                  : const Color(0xFF1C2A44).withOpacity(0.25),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              isFastest
                                  ? Icons.bolt
                                  : server.isCustom
                                      ? Icons.tune
                                      : Icons.dns,
                              color: isFastest
                                  ? const Color(0xFF00D1B2)
                                  : Colors.white70,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        server.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15),
                                      ),
                                    ),
                                    if (isFastest) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00D1B2).withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          '⚡ سریع‌ترین',
                                          style: TextStyle(
                                              color: Color(0xFF00D1B2),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  server.addresses.take(2).join('  •  '),
                                  textDirection: TextDirection.ltr,
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _pingColor(ping).withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _pingText(ping),
                                  style: TextStyle(
                                    color: _pingColor(ping),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 30,
                                child: TextButton(
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    backgroundColor: const Color(0xFF3AA6FF).withOpacity(0.1),
                                  ),
                                  onPressed: () {
                                    widget.onSelectAndConnect?.call(server);
                                    Navigator.pop(context, server);
                                  },
                                  child: const Text(
                                    'انتخاب',
                                    style: TextStyle(fontSize: 12, color: Color(0xFF3AA6FF)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
