import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dns_server.dart';
import '../models/license_info.dart';
import '../models/vpn_status.dart';
import '../services/custom_dns_service.dart';
import '../services/dns_catalog.dart';
import '../services/license_service.dart';
import '../services/version_service.dart';
import '../services/vpn_service.dart';
import '../widgets/server_card.dart';
import 'custom_dns_screen.dart';
import 'license_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final VpnServiceController _vpn = VpnServiceController();
  final LicenseService _license = LicenseService();
  final CustomDnsService _customDns = CustomDnsService();
  StreamSubscription<VpnStatus>? _statusSubscription;
  VpnStatus _status = const VpnStatus();
  String? _commandError;
  bool _commandPending = false;
  bool _loading = true;
  String selectedId = 'cloudflare';
  bool focusGame = false;
  String targetPackage = 'com.tencent.ig';
  bool get running => _status.isConnected;
  bool get busy => _commandPending || _status.isBusy;

  List<DnsServer> servers = List.of(freeDnsServers);
  LicenseInfo? licenseInfo;

  /// How often the app re-validates an active subscription while running, so a
  /// license/device ban from the panel takes effect within a minute instead of
  /// letting the user keep the private DNS for hours.
  static const Duration _licenseHeartbeatInterval = Duration(seconds: 45);
  Timer? _licenseHeartbeat;
  bool _licenseBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusSubscription = _vpn.states.listen(_applyStatus, onError: (_) {
      if (mounted) {
        setState(() => _commandError = vpnErrorMessage('unavailable'));
      }
    });
    _init();
  }

  Future<void> _init() async {
    await _loadLocalState();
    if (mounted && (licenseInfo?.isActive ?? false)) await _refreshLicense();
  }

  void _applyStatus(VpnStatus status) {
    if (!mounted || status.revision < _status.revision) return;
    setState(() {
      if (status.revision > _status.revision) _commandError = null;
      _status = status;
    });
  }

  Future<void> _syncVpnStatus() async {
    try {
      _applyStatus(await _vpn.getStatus());
    } catch (_) {
      if (mounted) {
        setState(() => _commandError = vpnErrorMessage('unavailable'));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncVpnStatus());
      // Coming back to the app is a good moment to re-validate the license so
      // a ban that happened while the app was in the background takes effect.
      if (licenseInfo?.isActive ?? false) unawaited(_refreshLicense());
    }
  }

  Future<void> _loadLocalState() async {
    await _license.load();
    final prefs = await SharedPreferences.getInstance();
    final custom = await _customDns.load();
    await _syncVpnStatus();
    if (!mounted) return;
    final nextServers = _buildServerList(custom, _license.cachedInfo);
    var nextId = prefs.getString('selected_server') ?? 'cloudflare';
    if (!nextServers.any((server) => server.id == nextId)) {
      nextId = 'cloudflare';
    }
    final nextServer = nextServers.firstWhere((server) => server.id == nextId);
    final nextFocus = prefs.getBool('focus_game') ?? false;
    final nextPackage = prefs.getString('target_package') ?? 'com.tencent.ig';
    final changed = _selectedServer?.id != nextId ||
        !listEquals(_selectedServer?.addresses, nextServer.addresses) ||
        focusGame != nextFocus ||
        targetPackage != nextPackage;
    // A paused session still holds its old configuration in the native service.
    // Clear it as well when a profile is edited/deleted or scope is changed.
    if (!_loading && _status.hasSession && changed) {
      if (!await _disconnectForChange()) return;
    }
    if (!mounted) return;
    setState(() {
      selectedId = nextId;
      focusGame = nextFocus;
      targetPackage = nextPackage;
      licenseInfo = _license.cachedInfo;
      servers = nextServers;
      _loading = false;
    });
    _syncLicenseHeartbeat();
    await prefs.setString('selected_server', selectedId);
  }

  /// Starts/stops the periodic subscription re-validation. Runs only while a
  /// license is cached and active, so a panel-side ban kicks in quickly.
  void _syncLicenseHeartbeat() {
    final shouldRun = _license.licenseKey != null &&
        _license.cachedInfo?.isActive == true &&
        mounted;
    if (shouldRun && _licenseHeartbeat == null) {
      _licenseHeartbeat = Timer.periodic(
        _licenseHeartbeatInterval,
        (_) => unawaited(_refreshLicense()),
      );
    } else if (!shouldRun && _licenseHeartbeat != null) {
      _licenseHeartbeat!.cancel();
      _licenseHeartbeat = null;
    }
  }

  List<DnsServer> _buildServerList(List<DnsServer> custom, LicenseInfo? info) {
    final list = <DnsServer>[...custom, ...freeDnsServers];
    if (info != null && info.isActive) {
      // A license's DNS IPs are ONE subscription profile: primary + secondary
      // together (like the built-in Cloudflare card with 1.1.1.1 + 1.0.0.1),
      // not one separate server per IP.
      final addresses = <String>[];
      for (final raw in info.dnsServers) {
        final address = raw.trim();
        if (address.isNotEmpty && !addresses.contains(address)) {
          addresses.add(address);
        }
      }
      if (addresses.isNotEmpty) {
        list.add(DnsServer(
          id: 'license_0',
          name: 'Subscription DNS',
          description: 'Private subscription server',
          addresses: addresses,
          isPremium: true,
        ));
      }
    }
    return list;
  }

  Future<void> _refreshLicense() async {
    if (_licenseBusy) return;
    _licenseBusy = true;
    try {
      // Always identify the device so a per-device ban is answered on check()
      // too, not only during the first activation.
      await _license.check(deviceId: await _license.ensureDeviceId());
      if (mounted) await _loadLocalState();
    } finally {
      _licenseBusy = false;
    }
  }

  DnsServer? get _selectedServer {
    for (final server in servers) {
      if (server.id == selectedId) return server;
    }
    return null;
  }

  Future<bool> _disconnectForChange() async {
    try {
      await _vpn.stop();
      await _syncVpnStatus();
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'DNS تغییر کرد؛ برای اعمال تنظیمات جدید، دوباره متصل شوید.')));
      return true;
    } catch (error) {
      _showError(error);
      return false;
    }
  }

  Future<void> _selectServer(DnsServer server) async {
    if (busy || server.id == selectedId) return;
    if (server.isPremium && !(licenseInfo?.isActive ?? false)) {
      await _openLicense();
      return;
    }
    setState(() => _commandPending = true);
    try {
      if (_status.hasSession && !await _disconnectForChange()) return;
      if (!mounted) return;
      setState(() => selectedId = server.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_server', server.id);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _commandPending = false);
    }
  }

  Future<void> _toggle() async {
    if (busy || VersionService.instance.updateRequired) return;
    if (running) {
      await _runCommand(_vpn.pause);
    } else if (_status.isPaused) {
      await _runCommand(_vpn.resume);
    } else {
      final server = _selectedServer;
      if (server == null) return;
      if (server.isPremium && !(licenseInfo?.isActive ?? false)) return;
      if (server.isPremium) {
        // Re-validate before handing out private DNS, so a license/device ban
        // made in the panel locks the subscription immediately.
        setState(() => _commandPending = true);
        LicenseInfo fresh;
        try {
          fresh =
              await _license.check(deviceId: await _license.ensureDeviceId());
        } finally {
          if (mounted) setState(() => _commandPending = false);
        }
        if (!mounted) return;
        if (!fresh.isActive) {
          final message = fresh.message;
          if (message != null && message.isNotEmpty) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          }
          await _loadLocalState();
          return;
        }
      }
      await _runCommand(() => _vpn.start(server.addresses,
          allowedPackages: focusGame ? [targetPackage] : <String>[]));
    }
  }

  Future<void> _runCommand(Future<void> Function() command) async {
    if (_commandPending) return;
    setState(() {
      _commandPending = true;
      _commandError = null;
    });
    try {
      await command();
      await _syncVpnStatus();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _commandPending = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _commandError = error is VpnException
        ? error.message
        : vpnErrorMessage('command_failed'));
  }

  Future<void> _openNotificationSettings() async {
    try {
      await _vpn.openNotificationSettings();
    } catch (error) {
      _showError(error);
    }
  }

  @override
  void dispose() {
    _licenseHeartbeat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _statusSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vs = VersionService.instance;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadLocalState();
            await _refreshLicense();
            await vs.refresh();
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _header(),
              const SizedBox(height: 20),
              _statusCard(),
              if (!_status.notificationsEnabled) ...[
                const SizedBox(height: 12),
                _notificationWarning(),
              ],
              const SizedBox(height: 20),
              if (licenseInfo != null && licenseInfo!.isActive) ...[
                _licenseBanner(),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Expanded(child: _sectionTitle('DNS Servers')),
                  TextButton.icon(
                    onPressed: _openCustomDns,
                    icon: const Icon(Icons.add),
                    label: const Text('DNS شخصی'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final s in servers) ...[
                ServerCard(
                  server: s,
                  selected: s.id == selectedId,
                  locked: s.isPremium && !(licenseInfo?.isActive ?? false),
                  onTap: busy ? null : () => _selectServer(s),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openLicense,
                icon: const Icon(Icons.workspace_premium),
                label: const Text('Activate subscription'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'DNS Changer',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: () => _openSettings(),
        ),
      ],
    );
  }

  String get _toggleLabel => _status.isBusy
      ? _status.label
      : running
          ? 'توقف موقت'
          : _status.isPaused
              ? 'ازسرگیری'
              : 'اتصال';

  Widget _statusCard() {
    final server = _selectedServer;
    final error = _commandError ?? _status.errorMessage;
    final accent = _status.isPaused
        ? const Color(0xFFFFC15C)
        : running
            ? const Color(0xFF00D1B2)
            : const Color(0xFF3AA6FF);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: running
              ? [const Color(0xFF0F5A8A), const Color(0xFF0A3A5C)]
              : [const Color(0xFF1C2A44), const Color(0xFF111B2E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: accent.withOpacity(0.15)),
                child: Icon(
                  _status.isPaused
                      ? Icons.pause_circle_outline
                      : running
                          ? Icons.shield
                          : Icons.shield_outlined,
                  color: accent,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_status.label,
                        key: const Key('vpn_status_label'),
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      server == null
                          ? 'No server selected'
                          : server.isPremium
                              ? '${server.name}  •  Private'
                              : '${server.name}  •  ${server.addresses.first}',
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_status.isPaused) ...[
            const SizedBox(height: 12),
            const Text(
                'تغییر DNS موقتاً خاموش است. برای ادامه، ازسرگیری را بزنید.',
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.6)),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error,
                key: const Key('vpn_error'),
                textDirection: TextDirection.rtl,
                style: const TextStyle(color: Colors.redAccent, height: 1.6)),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: 72,
            height: 72,
            child: FloatingActionButton.large(
              key: const Key('vpn_toggle'),
              heroTag: 'power',
              tooltip: _toggleLabel,
              backgroundColor: accent,
              foregroundColor: Colors.black,
              onPressed: busy ? null : _toggle,
              child: busy
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: Colors.black))
                  : Icon(
                      running
                          ? Icons.pause
                          : _status.isPaused
                              ? Icons.play_arrow
                              : Icons.power_settings_new,
                      size: 34),
            ),
          ),
          const SizedBox(height: 10),
          Text(_toggleLabel, textDirection: TextDirection.rtl),
          if (_status.hasSession) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('vpn_disconnect'),
              onPressed: _commandPending || _status.phase == VpnPhase.stopping
                  ? null
                  : () => _runCommand(_vpn.stop),
              icon: const Icon(Icons.power_settings_new),
              label: const Text('قطع اتصال'),
            ),
          ],
          const SizedBox(height: 8),
          if (focusGame)
            Text('Focused on $targetPackage',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _notificationWarning() {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('اعلان‌های برنامه خاموش‌اند',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text(
                  'برای دسترسی به توقف موقت، ازسرگیری و قطع اتصال از نوار اعلان، اعلان‌های برنامه را فعال کنید.',
                  style: TextStyle(color: Colors.white70, height: 1.6)),
              TextButton.icon(
                key: const Key('vpn_enable_notifications'),
                onPressed: _openNotificationSettings,
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('فعال کردن اعلان‌ها'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _licenseBanner() {
    final info = licenseInfo!;
    final days = info.expiresAt == null
        ? '∞'
        : info.expiresAt!.difference(DateTime.now()).inDays.toString();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F332B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF00D1B2).withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified, color: Color(0xFF00D1B2)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Subscription active',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Color(0xFF00D1B2)),
                ),
                Text(
                  '${info.deviceCount ?? 0}/${info.deviceLimit ?? '∞'} devices  •  $days days left',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white54),
            onPressed: _openLicense,
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _openLicense() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LicenseScreen()),
    );
    if (mounted) await _loadLocalState();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) await _loadLocalState();
  }

  Future<void> _openCustomDns() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CustomDnsScreen()),
    );
    if (mounted) await _loadLocalState();
  }
}
