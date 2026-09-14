import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_info.dart';
import '../services/app_filter_service.dart';
import '../services/target_package_policy.dart';

class AppFilterScreen extends StatefulWidget {
  const AppFilterScreen({super.key});

  @override
  State<AppFilterScreen> createState() => _AppFilterScreenState();
}

class _AppFilterScreenState extends State<AppFilterScreen> {
  final AppFilterService _filterService = AppFilterService();

  List<AppInfo> _allApps = [];
  Set<String> _selectedPackages = {};
  AppFilterMode _mode = AppFilterMode.all;
  bool _loading = true;
  bool _saving = false;
  bool _appsFailed = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _filterService.load();
    final apps = await _filterService.getInstalledApps();

    if (mounted) {
      setState(() {
        _allApps = apps;
        _appsFailed = _filterService.lastAppsLoadFailed;
        _mode = _filterService.mode;
        _selectedPackages = Set.from(_filterService.selectedPackages);
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    await _filterService.save(
      newMode: _mode,
      newPackages: _selectedPackages,
    );

    if (_mode == AppFilterMode.single) {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(TargetPackagePolicy.prefsKey);
      if (existing != null && existing.isNotEmpty) {
        await prefs.setString(TargetPackagePolicy.prefsKey, existing);
      }
    }

    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تنظیمات فیلتر برنامه‌ها ذخیره شد')),
      );
      Navigator.pop(context, true);
    }
  }

  List<AppInfo> get _filteredApps {
    if (_searchQuery.isEmpty) return _allApps;
    final q = _searchQuery.toLowerCase();
    return _allApps.where((app) {
      return app.appName.toLowerCase().contains(q) ||
          app.packageName.toLowerCase().contains(q);
    }).toList();
  }

  void _selectGames() {
    final vendorPrefixes = [
      'com.tencent',
      'com.activision',
      'com.supercell',
      'com.riotgames',
      'com.ea',
      'com.epicgames',
      'com.garena',
    ];
    final nameRe = RegExp(
      r'\b(games?|mobile legends|pubg|cod|free fire|clash|brawl)\b',
      caseSensitive: false,
    );
    final newSel = Set<String>.from(_selectedPackages);
    for (final app in _allApps) {
      final p = app.packageName.toLowerCase();
      final n = app.appName.toLowerCase();
      final vendor = vendorPrefixes.any((v) => p == v || p.startsWith('$v.'));
      if (vendor || nameRe.hasMatch(n) || nameRe.hasMatch(p.replaceAll('.', ' '))) {
        newSel.add(app.packageName);
      }
    }
    setState(() => _selectedPackages = newSel);
  }

  void _selectBrowsers() {
    final browserPatterns = ['chrome', 'firefox', 'opera', 'browser', 'edge', 'brave', 'safari'];
    final newSel = Set<String>.from(_selectedPackages);
    for (final app in _allApps) {
      final p = app.packageName.toLowerCase();
      final n = app.appName.toLowerCase();
      if (browserPatterns.any((b) => p.contains(b) || n.contains(b))) {
        newSel.add(app.packageName);
      }
    }
    setState(() => _selectedPackages = newSel);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('فیلتر برنامه‌ها (Split Tunneling)'),
          actions: [
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'ذخیره',
              onPressed: _loading || _saving ? null : _save,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // Mode selection header
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: const Color(0xFF111B2E),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'نحوهٔ اعمال DNS روی برنامه‌ها:',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 10),
                        RadioListTile<AppFilterMode>(
                          value: AppFilterMode.all,
                          groupValue: _mode,
                          onChanged: (v) => setState(() => _mode = v!),
                          title: const Text('همهٔ برنامه‌ها (پیش‌فرض)'),
                          subtitle: const Text(
                            'DNS روی تمام برنامه‌ها و ترافیک دستگاه اعمال می‌شود.',
                            style: TextStyle(fontSize: 12, color: Colors.white60),
                          ),
                          contentPadding: EdgeInsets.zero,
                          activeColor: const Color(0xFF00D1B2),
                        ),
                        RadioListTile<AppFilterMode>(
                          value: AppFilterMode.single,
                          groupValue: _mode,
                          onChanged: (v) => setState(() => _mode = v!),
                          title: const Text('تک‌برنامه (از تنظیمات)'),
                          subtitle: const Text(
                            'فقط برنامهٔ هدف ذخیره‌شده در تنظیمات (مثلاً بازی) از DNS استفاده می‌کند.',
                            style: TextStyle(fontSize: 12, color: Colors.white60),
                          ),
                          contentPadding: EdgeInsets.zero,
                          activeColor: const Color(0xFF00D1B2),
                        ),
                        RadioListTile<AppFilterMode>(
                          value: AppFilterMode.allowed,
                          groupValue: _mode,
                          onChanged: (v) => setState(() => _mode = v!),
                          title: const Text('فقط برنامه‌های انتخاب‌شده (Whitelist)'),
                          subtitle: const Text(
                            'DNS تنها برای برنامه‌های تیک‌خورده فعال می‌شود.',
                            style: TextStyle(fontSize: 12, color: Colors.white60),
                          ),
                          contentPadding: EdgeInsets.zero,
                          activeColor: const Color(0xFF00D1B2),
                        ),
                        RadioListTile<AppFilterMode>(
                          value: AppFilterMode.disallowed,
                          groupValue: _mode,
                          onChanged: (v) => setState(() => _mode = v!),
                          title: const Text('همه به جز برنامه‌های انتخاب‌شده (Bypass)'),
                          subtitle: const Text(
                            'برنامه‌های تیک‌خورده از DNS مستثنی شده و مستقیم وصل می‌شوند.',
                            style: TextStyle(fontSize: 12, color: Colors.white60),
                          ),
                          contentPadding: EdgeInsets.zero,
                          activeColor: const Color(0xFF00D1B2),
                        ),
                      ],
                    ),
                  ),

                  // Load failure notice
                  if (_appsFailed)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      color: const Color(0x33F59E0B),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFF59E0B)),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'دریافت فهرست برنامه‌های نصب‌شده ناموفق بود؛ فهرست پیشنهادی نمایش داده می‌شود.',
                              style: TextStyle(fontSize: 12, color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Quick action buttons
                  if (_mode != AppFilterMode.all && _mode != AppFilterMode.single) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.sports_esports, size: 16),
                              label: const Text('انتخاب بازی‌ها'),
                              onPressed: _selectGames,
                            ),
                            const SizedBox(width: 6),
                            ActionChip(
                              avatar: const Icon(Icons.public, size: 16),
                              label: const Text('انتخاب مرورگرها'),
                              onPressed: _selectBrowsers,
                            ),
                            const SizedBox(width: 6),
                            ActionChip(
                              avatar: const Icon(Icons.select_all, size: 16),
                              label: const Text('انتخاب همه'),
                              onPressed: () {
                                setState(() {
                                  _selectedPackages = _allApps.map((a) => a.packageName).toSet();
                                });
                              },
                            ),
                            const SizedBox(width: 6),
                            ActionChip(
                              avatar: const Icon(Icons.clear_all, size: 16),
                              label: const Text('لغو انتخاب'),
                              onPressed: () {
                                setState(() => _selectedPackages.clear());
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Search box
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: TextField(
                        onChanged: (v) => setState(() => _searchQuery = v),
                        decoration: InputDecoration(
                          hintText: 'جستجوی برنامه یا نام پکیج…',
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
                    ),
                  ],

                  // Apps list
                  if (_mode != AppFilterMode.all && _mode != AppFilterMode.single)
                    Expanded(
                      child: ListView.builder(
                        itemCount: _filteredApps.length,
                        itemBuilder: (context, index) {
                          final app = _filteredApps[index];
                          final isSelected = _selectedPackages.contains(app.packageName);

                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (bool? val) {
                              setState(() {
                                if (val == true) {
                                  _selectedPackages.add(app.packageName);
                                } else {
                                  _selectedPackages.remove(app.packageName);
                                }
                              });
                            },
                            title: Text(app.appName, style: const TextStyle(fontSize: 14)),
                            subtitle: Text(
                              app.packageName,
                              textDirection: TextDirection.ltr,
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 11, color: Colors.white54),
                            ),
                            secondary: CircleAvatar(
                              backgroundColor: const Color(0xFF1C2A44),
                              child: Text(
                                app.appName.isNotEmpty ? app.appName.characters.first.toUpperCase() : '?',
                                style: const TextStyle(color: Color(0xFF3AA6FF), fontWeight: FontWeight.bold),
                              ),
                            ),
                            activeColor: const Color(0xFF00D1B2),
                          );
                        },
                      ),
                    )
                  else
                    const Expanded(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'در این حالت، سرویس DNS روی تمام برنامه‌ها و بازی‌های گوشی اعمال می‌شود.\nبرای انتخاب برنامه‌های خاص، گزینه‌های بالا را انتخاب کنید.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54, height: 1.6),
                          ),
                        ),
                      ),
                    ),

                  // Bottom Save Bar
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: const Color(0xFF0B1220),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.save),
                        label: Text(_saving ? 'در حال ذخیره…' : 'ذخیره و اعمال تنظیمات'),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
