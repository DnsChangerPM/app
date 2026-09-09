import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dns_server.dart';
import '../models/license_info.dart';
import '../models/vpn_status.dart';
import '../services/app_filter_service.dart';
import '../services/custom_dns_service.dart';
import '../services/dns_catalog.dart';
import '../services/dns_settings_service.dart';
import '../services/dns_speed_test_service.dart';
import '../services/dns_stats_service.dart';
import '../services/license_service.dart';
import '../services/target_package_policy.dart';
import '../services/version_service.dart';
import '../services/vpn_service.dart';
import '../widgets/server_card.dart';
import 'app_filter_screen.dart';
import 'custom_dns_screen.dart';
import 'license_screen.dart';
import 'network_tools_screen.dart';
import 'settings_screen.dart';
import 'speed_test_screen.dart';
import 'stats_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.speedTest});

  /// Injectable for tests; defaults to the shared [DnsSpeedTestService.instance].
  final DnsSpeedTestService? speedTest;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final VpnServiceController _vpn = VpnServiceController();
  final LicenseService _license = LicenseService();
  final CustomDnsService _customDns = CustomDnsService();
  late final DnsSpeedTestService _speedTest;
  final DnsStatsService _stats = DnsStatsService.instance;
  final DnsSettingsService _settings = DnsSettingsService.instance;
  final AppFilterService _appFilter = AppFilterService();

  StreamSubscription<VpnStatus>? _statusSubscription;
  VpnStatus _status = const VpnStatus();
  String? _commandError;
  bool _commandPending = false;
  bool _loading = true;
  String selectedId = 'cloudflare';
  bool focusGame = false;
  String targetPackage = TargetPackagePolicy.defaultTargetPackage;
  bool get running => _status.isConnected;
  bool get busy => _commandPending || _status.isBusy;

  List<DnsServer> servers = List.of(freeDnsServers);
  LicenseInfo? licenseInfo;
  DnsCategory _selectedCategory = DnsCategory.all;
  String _searchQuery = '';
  int? _activePing;

  static const Duration _licenseHeartbeatInterval = Duration(seconds: 45);
  Timer? _licenseHeartbeat;
  bool _licenseBusy = false;

  @override
  void initState() {
    super.initState();
    _speedTest = widget.speedTest ?? DnsSpeedTestService.instance;
    WidgetsBinding.instance.addObserver(this);
    _stats.init();
    _settings.load();
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
    final wasConnected = _status.isConnected;
    final isNowConnected = status.isConnected;

    if (!wasConnected && isNowConnected) {
      _stats.onVpnConnected();
      _measureActivePing();
    } else if (wasConnected && !isNowConnected) {
      _stats.onVpnDisconnected();
    }

    setState(() {
      if (status.revision > _status.revision) _commandError = null;
      _status = status;
    });
  }

  Future<void> _measureActivePing() async {
    final server = _selectedServer;
    if (server == null) return;
    final ping = await _speedTest.pingServer(server);
    if (mounted && _status.isConnected) {
      setState(() => _activePing = ping);
    }
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
      if (licenseInfo?.isActive ?? false) unawaited(_refreshLicense());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSubscription?.cancel();
    _licenseHeartbeat?.cancel();
    if (_status.hasSession) {
      _stats.onVpnDisconnected();
    }
    super.dispose();
  }

  Future<void> _loadLocalState() async {
    await _license.load();
    await _appFilter.load();
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
    final nextPackage = TargetPackagePolicy.resolve(
      prefs.getString(TargetPackagePolicy.prefsKey),
      licenseActive: _license.cachedInfo?.isActive ?? false,
    );
    final changed = _selectedServer?.id != nextId ||
        !listEquals(_selectedServer?.addresses, nextServer.addresses) ||
        focusGame != nextFocus ||
        targetPackage != nextPackage;

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
          category: DnsCategory.general,
        ));
      }
    }
    return list;
  }

  Future<void> _refreshLicense() async {
    if (_licenseBusy) return;
    _licenseBusy = true;
    try {
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

  List<DnsServer> get _filteredServers {
    return servers.where((s) {
      if (_selectedCategory != DnsCategory.all && s.category != _selectedCategory) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchName = s.name.toLowerCase().contains(q);
        final matchDesc = s.description.toLowerCase().contains(q);
        final matchIp = s.addresses.any((a) => a.contains(q));
        if (!matchName && !matchDesc && !matchIp) return false;
      }
      return true;
    }).toList();
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
      setState(() {
        selectedId = server.id;
        _activePing = null;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_server', server.id);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _commandPending = false);
    }
  }

  Future<void> _autoSelectFastest() async {
    if (busy) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('در حال بررسی سرعت و انتخاب سریع‌ترین DNS…')),
    );

    final best = await _speedTest.findFastest(servers.where((s) => !s.isPremium || (licenseInfo?.isActive ?? false)).toList());
    if (best != null && mounted) {
      await _selectServer(best);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('سریع‌ترین سرور (${best.name}) انتخاب شد.')),
      );
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

      final filterScope = _appFilter.resolveForVpn(
        licenseActive: _license.cachedInfo?.isActive ?? false,
        singleTargetPackage: targetPackage,
      );

      final effectivePackages = focusGame
          ? [
              TargetPackagePolicy.resolve(
                targetPackage,
                licenseActive: _license.cachedInfo?.isActive ?? false,
              )
            ]
          : filterScope.allowed;

      await _runCommand(() => _vpn.start(
            server.addresses,
            allowedPackages: effectivePackages,
            disallowedPackages: filterScope.disallowed,
            enableIpv6: _settings.enableIpv6,
            timeoutMs: _settings.queryTimeoutMs,
          ));
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
    final message = error is VpnException ? error.message : error.toString();
    setState(() => _commandError = message);
  }

  Future<void> _openNotificationSettings() async {
    try {
      await _vpn.openNotificationSettings();
    } catch (error) {
      _showError(error);
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('DNS Changer', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => _openSettings(),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () async {
                  await _loadLocalState();
                  if (licenseInfo?.isActive ?? false) await _refreshLicense();
                },
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    _statusCard(),
                    if (!_status.notificationsEnabled) ...[
                      const SizedBox(height: 12),
                      _notificationWarning(),
                    ],
                    const SizedBox(height: 16),
                    _quickToolsBar(),
                    const SizedBox(height: 16),
                    if (licenseInfo != null && licenseInfo!.isActive) ...[
                      _licenseBanner(),
                      const SizedBox(height: 16),
                    ],

                    // Search & Category Chips
                    _searchAndFilterHeader(),
                    const SizedBox(height: 10),

                    // Server List
                    for (final s in _filteredServers) ...[
                      ServerCard(
                        server: s,
                        selected: s.id == selectedId,
                        locked: s.isPremium && !(licenseInfo?.isActive ?? false),
                        onTap: busy ? null : () => _selectServer(s),
                      ),
                      const SizedBox(height: 6),
                    ],

                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _openLicense,
                      icon: const Icon(Icons.workspace_premium),
                      label: const Text('Activate subscription'),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _quickToolsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111B2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _quickActionItem(
            icon: Icons.bolt,
            label: 'سریع‌ترین',
            color: const Color(0xFF00D1B2),
            onTap: _autoSelectFastest,
          ),
          _quickActionItem(
            icon: Icons.speed,
            label: 'تست پینگ',
            color: const Color(0xFF3AA6FF),
            onTap: () async {
              final selected = await Navigator.push<DnsServer>(
                context,
                MaterialPageRoute(
                  builder: (_) => SpeedTestScreen(
                    currentSelectedId: selectedId,
                    onSelectAndConnect: (server) => _selectServer(server),
                  ),
                ),
              );
              if (selected != null && mounted) {
                await _selectServer(selected);
              }
            },
          ),
          _quickActionItem(
            icon: Icons.filter_alt_outlined,
            label: 'فیلتر برنامه‌ها',
            color: const Color(0xFFFFC107),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppFilterScreen()),
            ).then((_) => _loadLocalState()),
          ),
          _quickActionItem(
            icon: Icons.insights,
            label: 'آمار و لاگ',
            color: const Color(0xFFFF5C5C),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StatsScreen(
                  activeServerName: _selectedServer?.name,
                  activePing: _activePing,
                  isConnected: running,
                ),
              ),
            ),
          ),
          _quickActionItem(
            icon: Icons.network_check,
            label: 'ابزارها',
            color: const Color(0xFF9D65FF),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => NetworkToolsScreen(
                  servers: servers,
                  activeServer: _selectedServer,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickActionItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  Widget _searchAndFilterHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle('DNS Servers')),
            TextButton.icon(
              onPressed: _openCustomDns,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('DNS شخصی'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          onChanged: (v) => setState(() => _searchQuery = v),
          decoration: InputDecoration(
            hintText: 'جستجوی سرورها بر اساس نام یا IP…',
            prefixIcon: const Icon(Icons.search, size: 20),
            filled: true,
            fillColor: const Color(0xFF111B2E),
            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: DnsCategory.values.map((cat) {
              final isSel = _selectedCategory == cat;
              return Padding(
                padding: const EdgeInsets.only(left: 6),
                child: FilterChip(
                  selected: isSel,
                  label: Text(cat.labelFa, style: const TextStyle(fontSize: 12)),
                  onSelected: (_) => setState(() => _selectedCategory = cat),
                  backgroundColor: const Color(0xFF111B2E),
                  selectedColor: const Color(0xFF3AA6FF).withOpacity(0.25),
                  checkmarkColor: const Color(0xFF3AA6FF),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              );
            }).toList(),
          ),
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
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: running ? const Color(0xFF00D1B2).withOpacity(0.3) : Colors.white.withOpacity(0.06),
          width: 1.2,
        ),
        boxShadow: running
            ? [
                BoxShadow(
                  color: const Color(0xFF00D1B2).withOpacity(0.12),
                  blurRadius: 20,
                  spreadRadius: 2,
                )
              ]
            : null,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withOpacity(0.15),
                  border: Border.all(color: accent.withOpacity(0.4), width: 1.5),
                ),
                child: Icon(
                  _status.isPaused
                      ? Icons.pause_circle_outline
                      : running
                          ? Icons.shield
                          : Icons.shield_outlined,
                  color: accent,
                  size: 28,
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
                            fontSize: 19, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      server == null
                          ? 'No server selected'
                          : server.isPremium
                              ? '${server.name}  •  Private'
                              : '${server.name}  •  ${server.addresses.first}',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    if (running) ...[
                      const SizedBox(height: 4),
                      ListenableBuilder(
                        listenable: _stats,
                        builder: (context, _) => Row(
                          children: [
                            const Icon(Icons.timer_outlined, size: 14, color: Color(0xFF00D1B2)),
                            const SizedBox(width: 4),
                            Text(
                              _formatDuration(_stats.sessionDuration),
                              style: const TextStyle(
                                color: Color(0xFF00D1B2),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (_activePing != null) ...[
                              const SizedBox(width: 10),
                              const Icon(Icons.bolt, size: 14, color: Color(0xFF3AA6FF)),
                              const SizedBox(width: 2),
                              Text(
                                '$_activePing ms',
                                style: const TextStyle(
                                  color: Color(0xFF3AA6FF),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
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
            width: 76,
            height: 76,
            child: FloatingActionButton.large(
              key: const Key('vpn_toggle'),
              heroTag: 'power',
              tooltip: _toggleLabel,
              backgroundColor: accent,
              foregroundColor: Colors.black,
              elevation: 4,
              onPressed: busy ? null : _toggle,
              child: busy
                  ? const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                          strokeWidth: 3, color: Colors.black))
                  : Icon(
                      running
                          ? Icons.pause
                          : _status.isPaused
                              ? Icons.play_arrow
                              : Icons.power_settings_new,
                      size: 38),
            ),
          ),
          const SizedBox(height: 10),
          Text(_toggleLabel, textDirection: TextDirection.rtl, style: const TextStyle(fontWeight: FontWeight.bold)),
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
                const Text(
                  'Subscription active',
                  style: TextStyle(
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
