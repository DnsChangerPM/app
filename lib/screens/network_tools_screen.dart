import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import '../models/dns_server.dart';
import '../services/dns_speed_test_service.dart';
import '../services/vpn_service.dart';

class NetworkToolsScreen extends StatefulWidget {
  final List<DnsServer> servers;
  final DnsServer? activeServer;

  const NetworkToolsScreen({
    super.key,
    required this.servers,
    this.activeServer,
  });

  @override
  State<NetworkToolsScreen> createState() => _NetworkToolsScreenState();
}

class _NetworkToolsScreenState extends State<NetworkToolsScreen> {
  final VpnServiceController _vpn = VpnServiceController();
  final TextEditingController _hostController = TextEditingController(text: 'google.com');

  Map<String, dynamic>? _netInfo;
  bool _loadingNet = true;
  bool _resolving = false;
  List<String> _resolvedIps = [];
  int? _resolveLatency;
  String? _resolveError;
  DnsServer? _testServer;

  @override
  void initState() {
    super.initState();
    _testServer = widget.activeServer ?? widget.servers.firstOrNull;
    _loadNetInfo();
  }

  Future<void> _loadNetInfo() async {
    final info = await _vpn.getNetworkInfo();
    if (mounted) {
      setState(() {
        _netInfo = info;
        _loadingNet = false;
      });
    }
  }

  Future<void> _performLookup() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;

    setState(() {
      _resolving = true;
      _resolveError = null;
      _resolvedIps = [];
      _resolveLatency = null;
    });

    final stopwatch = Stopwatch()..start();

    try {
      final results = await InternetAddress.lookup(host);
      stopwatch.stop();
      if (mounted) {
        setState(() {
          _resolving = false;
          _resolveLatency = stopwatch.elapsedMilliseconds;
          _resolvedIps = results.map((r) => r.address).toList();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _resolving = false;
          _resolveError = 'استعلام ناموفق بود؛ دامنه یا اتصال اینترنت را بررسی کنید.';
        });
      }
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ابزارهای شبکه و بررسی DNS'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadNetInfo,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Network Status Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111B2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.wifi, color: Color(0xFF00D1B2)),
                      const SizedBox(width: 8),
                      const Text(
                        'وضعیت اتصال فعلی',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _infoRow('نوع اتصال', _netInfo?['type']?.toString().toUpperCase() ?? 'نامشخص'),
                  _infoRow('وضعیت اینترنت', _netInfo?['isConnected'] == true ? 'متصل (Online)' : 'قطع'),
                  _infoRow('سرور انتخابی', widget.activeServer?.name ?? 'انتخاب نشده'),
                  _infoRow('آدرس‌های سرور', widget.activeServer?.addresses.join(', ') ?? '--'),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // DNS Lookup Tester
            const Text(
              'تست استعلام دامنه (DNS Lookup Test)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'یک آدرس یا دامنه وارد کنید تا آی‌پی‌ها و زمان پاسخ‌دهی را مستقیماً مشاهده نمایید.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hostController,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: 'مثال: google.com',
                      filled: true,
                      fillColor: const Color(0xFF111B2E),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _resolving ? null : _performLookup,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                    backgroundColor: const Color(0xFF3AA6FF),
                  ),
                  child: _resolving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('استعلام'),
                ),
              ],
            ),

            if (_resolveLatency != null || _resolvedIps.isNotEmpty || _resolveError != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1E33),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF3AA6FF).withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_resolveLatency != null)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('زمان پاسخ‌دهی (Latency):', style: TextStyle(color: Colors.white70)),
                          Text(
                            '$_resolveLatency ms',
                            style: const TextStyle(
                                color: Color(0xFF00D1B2), fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    if (_resolvedIps.isNotEmpty) ...[
                      const Divider(height: 16),
                      const Text('آی‌پی‌های پاسخ داده‌شده:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      for (final ip in _resolvedIps)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '• $ip',
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.right,
                            style: const TextStyle(color: Color(0xFF3AA6FF), fontFamily: 'monospace'),
                          ),
                        ),
                    ],
                    if (_resolveError != null)
                      Text(_resolveError!, style: const TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // DNS Leak Prevention Info Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF111B2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.shield_outlined, color: Color(0xFF3AA6FF)),
                      const SizedBox(width: 8),
                      const Text(
                        'حفاظت در برابر نشت DNS (Anti-Leak)',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'این برنامه با مسیریابی مستقیم بسته‌های UDP و TCP پورت ۵۳ درون تونل امن VPN اختصاصی، از ارسال هرگونه درخواست به دی‌ان‌اس اپراتور (ISP) جلوگیری کرده و هویت و حریم خصوصی شما را کاملاً محافظت می‌کند.',
                    style: TextStyle(color: Colors.white70, height: 1.6, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
