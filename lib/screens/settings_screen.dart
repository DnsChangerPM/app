import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_config.dart';
import '../services/version_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiController = TextEditingController();
  final TextEditingController _pkgController = TextEditingController();
  bool focusGame = true;
  String version = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _apiController.text = AppConfig.apiBaseUrl;
    _pkgController.text = prefs.getString('target_package') ?? 'com.tencent.ig';
    focusGame = prefs.getBool('focus_game') ?? true;
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version} (${info.buildNumber})';
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await AppConfig.setApiBaseUrl(_apiController.text);
    await prefs.setString('target_package', _pkgController.text.trim());
    await prefs.setBool('focus_game', focusGame);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            value: focusGame,
            onChanged: (v) => setState(() => focusGame = v),
            title: const Text('Focus on a specific app'),
            subtitle: const Text(
              'Route only the selected app through the DNS tunnel. '
              'Turn off to apply to all apps.',
              style: TextStyle(color: Colors.white54),
            ),
            contentPadding: EdgeInsets.zero,
            activeColor: const Color(0xFF00D1B2),
          ),
          TextField(
            controller: _pkgController,
            decoration: _decoration('Target package name', 'com.tencent.ig'),
          ),
          const SizedBox(height: 24),
          const Text('Cloudflare API', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _apiController,
            decoration: _decoration('Worker URL', 'https://xxx.workers.dev'),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('App version'),
            subtitle: Text(version.isEmpty ? '…' : version),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update),
            title: const Text('Check for updates'),
            onTap: () async {
              final vs = VersionService.instance;
              await vs.refresh();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    vs.updateRequired
                        ? 'Update required!'
                        : 'You are up to date (${vs.currentVersion}).',
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String label, String hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: const Color(0xFF111B2E),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}
