import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/license_info.dart';
import '../services/license_service.dart';

class LicenseScreen extends StatefulWidget {
  const LicenseScreen({super.key});

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  final LicenseService _service = LicenseService();
  final TextEditingController _keyController = TextEditingController();

  bool loading = false;
  LicenseInfo? info;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _service.load();
    setState(() {
      info = _service.cachedInfo;
      _keyController.text = _service.licenseKey ?? '';
    });
  }

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      final rand = Random.secure();
      id = List.generate(16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString('device_id', id);
    }
    return id;
  }

  Future<void> _activate() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      _snack('Enter your license key');
      return;
    }
    setState(() => loading = true);
    try {
      await _service.setLicenseKey(key);
      final result = await _service.validate(
        deviceName: 'Android',
        deviceId: await _deviceId(),
      );
      setState(() => info = result);
      _snack(result.message ?? (result.isActive ? 'Activated!' : 'Activation failed'));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _deactivate() async {
    await _service.clear();
    setState(() {
      info = null;
      _keyController.clear();
    });
    _snack('License removed');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final active = info?.isActive ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Subscription')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (active) ...[
            _activeCard(),
            const SizedBox(height: 20),
          ] else ...[
            const Icon(Icons.workspace_premium, size: 64, color: Color(0xFF00D1B2)),
            const SizedBox(height: 12),
            const Text(
              'Enter your license key',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Your private DNS servers are locked until you activate a valid subscription.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, height: 1.4),
            ),
            const SizedBox(height: 24),
          ],
          TextField(
            controller: _keyController,
            obscureText: false,
            decoration: InputDecoration(
              labelText: 'License key',
              hintText: 'XXXX-XXXX-XXXX-XXXX',
              filled: true,
              fillColor: const Color(0xFF111B2E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => _keyController.clear(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00D1B2),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: loading ? null : _activate,
            icon: loading
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(Icons.check_circle_outline),
            label: Text(active ? 'Refresh' : 'Activate'),
          ),
          if (active) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _deactivate,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              label: const Text('Remove license', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'The license ties your device to your subscription. If you hit the device '
            'limit, contact your admin to remove an old device.',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _activeCard() {
    final i = info!;
    final daysLeft = i.expiresAt == null
        ? '∞'
        : i.expiresAt!.difference(DateTime.now()).inDays.toString();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0F332B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF00D1B2).withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified, color: Color(0xFF00D1B2)),
              const SizedBox(width: 8),
              Text(
                i.planName ?? 'Subscription',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF00D1B2)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _row('Status', i.status.toUpperCase()),
          _row('Devices', '${i.deviceCount ?? 0} / ${i.deviceLimit ?? '∞'}'),
          _row('Expires', i.expiresAt == null ? 'Lifetime' : '${i.expiresAt!.toLocal()}'.substring(0, 16)),
          _row('Days left', daysLeft),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
