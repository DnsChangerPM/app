import 'package:flutter/material.dart';

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
  LicenseInfo? lastError;
  bool checkingServer = false;
  String? serverCheckResult;

  /// True when the last activation failed for a server-side reason
  /// (missing/old endpoint or unreachable host) rather than a bad key.
  bool get _serverRelatedFailure =>
      lastError != null &&
      (lastError!.status == 'server_not_found' ||
          lastError!.status == 'server_error' ||
          lastError!.status == 'unreachable');

  /// An explicit access block (license banned/revoked/expired, this device
  /// banned, or the device limit reached). Rendered as a clear card instead of
  /// a one-off snackbar so the user understands why access stopped.
  LicenseInfo? get _blockedInfo {
    final candidate = lastError ?? info;
    if (candidate == null || candidate.isActive) return null;
    const blocked = {
      'banned',
      'revoked',
      'expired',
      'device_banned',
      'limit_reached',
    };
    return blocked.contains(candidate.status) ? candidate : null;
  }

  String _blockedTitle(String status) {
    switch (status) {
      case 'banned':
        return 'لایسنس بن شده است';
      case 'revoked':
        return 'لایسنس لغو شده است';
      case 'expired':
        return 'لایسنس منقضی شده است';
      case 'device_banned':
        return 'این دستگاه از لایسنس بن شده است';
      case 'limit_reached':
        return 'سقف تعداد دستگاه‌ها پر است';
      default:
        return 'دسترسی غیرفعال است';
    }
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _service.load();
    if (!mounted) return;
    setState(() {
      info = _service.cachedInfo;
      _keyController.text = _service.licenseKey ?? '';
    });
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
        deviceId: await _service.ensureDeviceId(),
      );
      if (!mounted) return;
      setState(() {
        info = result;
        lastError = result.isActive ? null : result;
        if (!result.isActive && _serverRelatedFailure) {
          serverCheckResult = null;
        }
      });
      _snack(result.message ??
          (result.isActive ? 'Activated!' : 'Activation failed'));
    } catch (_) {
      // Network exceptions can contain the private API URL; never show them.
      _snack('ارتباط با سرویس برقرار نشد؛ دوباره تلاش کنید.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _checkServer() async {
    setState(() {
      checkingServer = true;
      serverCheckResult = null;
    });
    final health = await _service.checkServerHealth();
    if (!mounted) return;
    setState(() {
      checkingServer = false;
      serverCheckResult = health.message;
      // An explicit green health check means the endpoint is configured right,
      // even if the previous activation failed for another reason.
      if (health.ok) lastError = null;
    });
    _snack(health.ok ? 'Server appears to be online' : 'Server check failed');
  }

  Future<void> _deactivate() async {
    await _service.clear();
    if (!mounted) return;
    setState(() {
      info = null;
      lastError = null;
      serverCheckResult = null;
      _keyController.clear();
    });
    _snack('License removed');
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
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
            const Icon(Icons.workspace_premium,
                size: 64, color: Color(0xFF00D1B2)),
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
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(Icons.check_circle_outline),
            label: Text(active ? 'Refresh' : 'Activate'),
          ),
          if (active) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _deactivate,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              label: const Text('Remove license',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ] else if (_serverRelatedFailure) ...[
            const SizedBox(height: 16),
            _serverHelpCard(),
          ] else if (_blockedInfo != null) ...[
            const SizedBox(height: 16),
            _blockedCard(_blockedInfo!),
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

  Widget _serverHelpCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1620),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF5C5C).withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_off, color: Color(0xFFFF5C5C)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'مشکل از سمت سرور است',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            lastError?.message ?? '',
            style: const TextStyle(color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF3AA6FF),
              side: const BorderSide(color: Color(0xFF3AA6FF)),
            ),
            onPressed: checkingServer ? null : _checkServer,
            icon: checkingServer
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check, size: 18),
            label: const Text('بررسی وضعیت سرور'),
          ),
          if (serverCheckResult != null) ...[
            const SizedBox(height: 10),
            Text(
              serverCheckResult!,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _blockedCard(LicenseInfo blocked) {
    final color = blocked.status == 'expired'
        ? const Color(0xFFFFC107)
        : blocked.status == 'limit_reached'
            ? const Color(0xFF3AA6FF)
            : const Color(0xFFFF5C5C);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1620),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.block, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _blockedTitle(blocked.status),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          if ((blocked.message ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              blocked.message!,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
          ],
          if (blocked.status == 'device_banned' ||
              blocked.status == 'banned' ||
              blocked.status == 'revoked') ...[
            const SizedBox(height: 8),
            const Text(
              'اگر فکر می‌کنید اشتباه شده، با پشتیبانی/فروشنده تماس بگیرید.',
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
          ],
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
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00D1B2)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _row('Status', i.status.toUpperCase()),
          _row('Devices', '${i.deviceCount ?? 0} / ${i.deviceLimit ?? '∞'}'),
          _row(
              'Expires',
              i.expiresAt == null
                  ? 'Lifetime'
                  : '${i.expiresAt!.toLocal()}'.substring(0, 16)),
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
