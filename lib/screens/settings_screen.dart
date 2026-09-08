import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_config.dart';
import '../services/version_service.dart';
import '../services/vpn_service.dart';
import 'custom_dns_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _pkgController = TextEditingController();
  bool focusGame = false;
  bool _loading = true;
  bool _saving = false;
  bool _checking = false;
  String version = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _pkgController.text = prefs.getString('target_package') ?? 'com.tencent.ig';
    focusGame = prefs.getBool('focus_game') ?? false;
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version} (${info.buildNumber})';
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _pkgController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    final package = _pkgController.text.trim();
    if (focusGame &&
        !RegExp(r'^[a-zA-Z]\w*(\.[a-zA-Z]\w*)+$').hasMatch(package)) {
      _snack('نام پکیج برنامه را درست وارد کنید؛ مثلاً com.tencent.ig');
      return;
    }
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('target_package', package);
      await prefs.setBool('focus_game', focusGame);
      _snack('تنظیمات ذخیره شد');
    } catch (_) {
      _snack('ذخیره انجام نشد؛ دوباره تلاش کنید.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _checkUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    final service = VersionService.instance;
    await service.refresh();
    if (!mounted) return;
    setState(() => _checking = false);
    _snack(service.updateRequired
        ? 'برای ادامه، برنامه را به‌روزرسانی کنید.'
        : service.lastCheckSucceeded
            ? 'برنامه به‌روز است (${service.currentVersion}).'
            : 'بررسی نسخه انجام نشد؛ اتصال اینترنت را بررسی کنید.');
  }

  Future<void> _openTelegram(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _snack('باز کردن لینک ممکن نشد.');
    } catch (_) {
      _snack('باز کردن لینک ممکن نشد؛ تلگرام یا مرورگر را بررسی کنید.');
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await VpnServiceController().openNotificationSettings();
    } catch (_) {
      _snack('باز کردن تنظیمات اعلان ممکن نشد؛ از تنظیمات اندروید اقدام کنید.');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تنظیمات')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  SwitchListTile(
                    value: focusGame,
                    onChanged:
                        _saving ? null : (v) => setState(() => focusGame = v),
                    title: const Text('اعمال DNS فقط روی یک برنامه'),
                    subtitle: const Text(
                      'برای اعمال DNS روی همهٔ برنامه‌ها، این گزینه را خاموش کنید.',
                      style: TextStyle(color: Colors.white54),
                    ),
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF00D1B2),
                  ),
                  TextField(
                    controller: _pkgController,
                    enabled: focusGame && !_saving,
                    textDirection: TextDirection.ltr,
                    autocorrect: false,
                    decoration:
                        _decoration('نام پکیج برنامه', 'com.tencent.ig'),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'در حال ذخیره…' : 'ذخیرهٔ تنظیمات'),
                  ),
                  const SizedBox(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.add_circle_outline),
                    title: const Text('DNS شخصی'),
                    subtitle: const Text('افزودن، ویرایش و حذف DNS دلخواه'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const CustomDnsScreen()),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.notifications_active_outlined),
                    title: const Text('اعلان وضعیت اتصال'),
                    subtitle: const Text(
                        'فعال‌سازی اعلان با دکمه‌های توقف موقت، ازسرگیری و قطع اتصال'),
                    onTap: _openNotificationSettings,
                  ),
                  const Divider(height: 32),
                  const Text('ارتباط با ما',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  _telegramTile('کانال تلگرام', '@DnsChangerPM',
                      AppConfig.telegramChannel, Icons.campaign_outlined),
                  _telegramTile('گروه تلگرام', '@DnsChangerPMGP',
                      AppConfig.telegramGroup, Icons.groups_outlined),
                  _telegramTile('سازنده', '@AnishtayiN',
                      AppConfig.telegramCreator, Icons.person_outline),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline),
                    title: const Text('نسخهٔ برنامه'),
                    subtitle: Text(version.isEmpty ? '…' : version,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update),
                    title:
                        Text(_checking ? 'در حال بررسی…' : 'بررسی به‌روزرسانی'),
                    onTap: _checking ? null : _checkUpdates,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _telegramTile(String title, String handle, String url, IconData icon) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: const Color(0xFF3AA6FF)),
      title: Text(title),
      subtitle: Text(handle,
          textDirection: TextDirection.ltr, textAlign: TextAlign.right),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => _openTelegram(url),
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
