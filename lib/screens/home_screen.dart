import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/dns_server.dart';
import '../models/license_info.dart';
import '../services/dns_catalog.dart';
import '../services/license_service.dart';
import '../services/version_service.dart';
import '../services/vpn_service.dart';
import '../widgets/server_card.dart';
import '../widgets/update_gate.dart';
import 'license_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final VpnServiceController _vpn = VpnServiceController();
  final LicenseService _license = LicenseService();

  bool running = false;
  bool busy = false;
  String selectedId = 'cloudflare';
  bool focusGame = true;
  String targetPackage = 'com.tencent.ig';

  List<DnsServer> servers = List.of(freeDnsServers);
  LicenseInfo? licenseInfo;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _license.load();
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    selectedId = prefs.getString('selected_server') ?? 'cloudflare';
    focusGame = prefs.getBool('focus_game') ?? true;
    targetPackage = prefs.getString('target_package') ?? 'com.tencent.ig';

    licenseInfo = _license.cachedInfo;
    if (licenseInfo != null && licenseInfo!.isActive) {
      await _refreshLicense(activate: false);
    }
    if (!mounted) return;

    setState(() {
      servers = _buildServerList();
    });
    running = await _vpn.isRunning();
    if (mounted) setState(() {});

    // Re-check for updates and rebuild if a forced update is required.
    VersionService.instance.refresh().then((_) {
      if (mounted) setState(() {});
    });
  }

  List<DnsServer> _buildServerList() {
    final list = List<DnsServer>.of(freeDnsServers);
    final info = licenseInfo;
    if (info != null && info.isActive) {
      final names = info.dnsServers;
      for (var i = 0; i < names.length; i++) {
        list.add(DnsServer(
          id: 'license_$i',
          name: 'Subscription DNS',
          description: 'Private subscription server',
          addresses: [names[i]],
          isPremium: true,
        ));
      }
    }
    return list;
  }

  Future<void> _refreshLicense({required bool activate}) async {
    LicenseInfo info;
    if (activate) {
      info = await _license.validate();
    } else {
      info = await _license.check();
    }
    if (mounted) {
      setState(() {
        licenseInfo = info;
        servers = _buildServerList();
      });
    }
  }

  DnsServer? get _selectedServer {
    for (final s in servers) {
      if (s.id == selectedId) return s;
    }
    return servers.isNotEmpty ? servers.first : null;
  }

  bool get _selectedLocked {
    final s = _selectedServer;
    return s != null && s.isPremium && !(licenseInfo?.isActive ?? false);
  }

  Future<void> _toggle() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (running) {
        await _vpn.stop();
        setState(() => running = false);
      } else {
        if (_selectedLocked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This server needs an active subscription.')),
          );
          return;
        }
        final server = _selectedServer;
        if (server == null) return;
        final allowed = focusGame ? [targetPackage] : <String>[];
        final started = await _vpn.start(server.addresses, allowedPackages: allowed);
        if (started) {
          setState(() => running = true);
        } else {
          // Permission dialog shown: poll until it starts.
          _pollTimer?.cancel();
          _pollTimer = Timer.periodic(const Duration(milliseconds: 700), (_) async {
            final r = await _vpn.isRunning();
            if (r) {
              _pollTimer?.cancel();
              if (mounted) setState(() => running = true);
            }
          });
          // Safety timeout.
          Timer(const Duration(seconds: 12), () {
            _pollTimer?.cancel();
          });
        }
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vs = VersionService.instance;
    if (vs.updateRequired) {
      return UpdateGate(
        release: vs.latestRelease,
        onRetry: () async {
          await vs.refresh();
          if (mounted) setState(() {});
        },
      );
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await _refreshLicense(activate: false);
            await vs.refresh();
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _header(vs),
              const SizedBox(height: 20),
              _statusCard(),
              const SizedBox(height: 20),
              if (licenseInfo != null && licenseInfo!.isActive) ...[
                _licenseBanner(),
                const SizedBox(height: 16),
              ],
              _sectionTitle('DNS Servers'),
              const SizedBox(height: 8),
              for (final s in servers) ...[
                ServerCard(
                  server: s,
                  selected: s.id == selectedId,
                  locked: s.isPremium && !(licenseInfo?.isActive ?? false),
                  onTap: () {
                    if (s.isPremium && !(licenseInfo?.isActive ?? false)) {
                      _openLicense();
                      return;
                    }
                    setState(() => selectedId = s.id);
                    SharedPreferences.getInstance()
                        .then((p) => p.setString('selected_server', s.id));
                  },
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

  Widget _header(VersionService vs) {
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
          onPressed: () => _openSettings(),
        ),
      ],
    );
  }

  Widget _statusCard() {
    final server = _selectedServer;
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
                  shape: BoxShape.circle,
                  color: running ? const Color(0xFF00D1B2) : const Color(0xFF2A3B58),
                ),
                child: Icon(
                  running ? Icons.shield : Icons.shield_outlined,
                  color: running ? Colors.black : Colors.white54,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      running ? 'Protected' : 'Not connected',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      server == null
                          ? 'No server selected'
                          : '${server.name}  •  ${server.addresses.first}',
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: 72,
            height: 72,
            child: FloatingActionButton.large(
              heroTag: 'power',
              backgroundColor: running ? const Color(0xFF00D1B2) : const Color(0xFF3AA6FF),
              foregroundColor: Colors.black,
              onPressed: busy ? null : _toggle,
              child: busy
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black),
                    )
                  : Icon(running ? Icons.power_settings_new : Icons.power_settings_new,
                      size: 34),
            ),
          ),
          const SizedBox(height: 8),
          if (focusGame)
            Text(
              'Focused on $targetPackage',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
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
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00D1B2)),
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

  void _openLicense() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LicenseScreen()));
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }
}
