import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/dns_stats_service.dart';

class StatsScreen extends StatefulWidget {
  final String? activeServerName;
  final int? activePing;
  final bool isConnected;

  const StatsScreen({
    super.key,
    this.activeServerName,
    this.activePing,
    this.isConnected = false,
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final DnsStatsService _stats = DnsStatsService.instance;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _stats.addListener(_onStatsChanged);
  }

  @override
  void dispose() {
    _stats.removeListener(_onStatsChanged);
    super.dispose();
  }

  void _onStatsChanged() {
    if (mounted) setState(() {});
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final logs = _stats.recentLogs.where((l) {
      if (_searchQuery.isEmpty) return true;
      return l.domain.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          l.serverName.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('آمار و گزارش دی‌ان‌اس'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'پاک‌سازی گزارش‌ها',
              onPressed: () {
                _stats.clearLogs();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('گزارش کوئری‌ها پاک شد')),
                );
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Stat Cards Grid
            Row(
              children: [
                Expanded(
                  child: _statCard(
                    title: 'مدت اتصال فعلی',
                    value: widget.isConnected ? _formatDuration(_stats.sessionDuration) : '۰:۰۰:۰۰',
                    icon: Icons.timer_outlined,
                    color: const Color(0xFF00D1B2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _statCard(
                    title: 'کوئری‌های نشست',
                    value: '${_stats.sessionQueries}',
                    icon: Icons.query_stats,
                    color: const Color(0xFF3AA6FF),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _statCard(
                    title: 'مجموع کل کوئری‌ها',
                    value: '${_stats.allTimeQueries}',
                    icon: Icons.all_inclusive,
                    color: const Color(0xFFFFC107),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _statCard(
                    title: 'پینگ سرور فعال',
                    value: widget.activePing != null ? '${widget.activePing} ms' : '--',
                    icon: Icons.bolt,
                    color: const Color(0xFFFF5C5C),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Logging Switch
            SwitchListTile(
              value: _stats.loggingEnabled,
              onChanged: (v) => _stats.setLoggingEnabled(v),
              title: const Text('ثبت تاریخچه درخواست‌های DNS'),
              subtitle: const Text(
                'تمام اطلاعات فقط در حافظهٔ داخلی دستگاه شما ذخیره می‌شود.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              contentPadding: EdgeInsets.zero,
              activeColor: const Color(0xFF00D1B2),
            ),

            const Divider(height: 32),

            // Logs Section Header
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'درخواست‌های اخیر (Query Log)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                if (logs.isNotEmpty)
                  Text(
                    '${logs.length} مورد',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Search Bar
            TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'جستجوی دامنه در گزارش‌ها…',
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
            const SizedBox(height: 12),

            if (logs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.history_toggle_off, size: 48, color: Colors.white.withOpacity(0.2)),
                      const SizedBox(height: 12),
                      const Text(
                        'هنوز درخواستی ثبت نشده است.\nبا فعال بودن DNS، دامنه‌های استعلام‌شده در اینجا نمایش می‌یابند.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, height: 1.5),
                      ),
                    ],
                  ),
                ),
              )
            else
              for (final entry in logs)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: const Color(0xFF111B2E),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    title: Text(
                      entry.domain,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    subtitle: Row(
                      children: [
                        Text(
                          '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          entry.serverName,
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D1B2).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${entry.latencyMs} ms',
                        style: const TextStyle(
                          color: Color(0xFF00D1B2),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _statCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 22),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
