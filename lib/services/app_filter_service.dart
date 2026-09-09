import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_info.dart';
import 'target_package_policy.dart';

class AppFilterService {
  static const MethodChannel _channel = MethodChannel('com.dnschanger.app/vpn');

  static const String keyFilterMode = 'app_filter_mode';
  static const String keySelectedPackages = 'app_filter_packages';

  AppFilterMode mode = AppFilterMode.all;
  Set<String> selectedPackages = {};

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString(keyFilterMode);
    if (modeStr != null) {
      mode = AppFilterMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => AppFilterMode.all,
      );
    } else {
      // Backward compatibility check
      final legacyFocus = prefs.getBool('focus_game') ?? false;
      if (legacyFocus) {
        mode = AppFilterMode.single;
      } else {
        mode = AppFilterMode.all;
      }
    }

    final pkgs = prefs.getStringList(keySelectedPackages);
    if (pkgs != null) {
      selectedPackages = pkgs.toSet();
    }
  }

  Future<void> save({AppFilterMode? newMode, Set<String>? newPackages}) async {
    final prefs = await SharedPreferences.getInstance();
    if (newMode != null) {
      mode = newMode;
      await prefs.setString(keyFilterMode, newMode.name);
      // Sync legacy key
      await prefs.setBool('focus_game', newMode == AppFilterMode.single || newMode == AppFilterMode.allowed);
    }
    if (newPackages != null) {
      selectedPackages = newPackages;
      await prefs.setStringList(keySelectedPackages, newPackages.toList());
    }
  }

  Future<List<AppInfo>> getInstalledApps() async {
    try {
      final result = await _channel.invokeListMethod<Map<dynamic, dynamic>>('getInstalledApps');
      if (result != null && result.isNotEmpty) {
        return result.map((m) => AppInfo.fromMap(m)).toList()
          ..sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
      }
    } catch (_) {}

    // Fallback list of common apps for simulator / testing
    return const [
      AppInfo(packageName: 'com.tencent.ig', appName: 'PUBG Mobile'),
      AppInfo(packageName: 'com.activision.callofduty.shooter', appName: 'Call of Duty: Mobile'),
      AppInfo(packageName: 'com.supercell.clashofclans', appName: 'Clash of Clans'),
      AppInfo(packageName: 'com.supercell.brawlstars', appName: 'Brawl Stars'),
      AppInfo(packageName: 'com.dts.freefireth', appName: 'Free Fire'),
      AppInfo(packageName: 'com.android.chrome', appName: 'Google Chrome'),
      AppInfo(packageName: 'org.mozilla.firefox', appName: 'Firefox Browser'),
      AppInfo(packageName: 'com.google.android.youtube', appName: 'YouTube'),
      AppInfo(packageName: 'org.telegram.messenger', appName: 'Telegram'),
      AppInfo(packageName: 'com.instagram.android', appName: 'Instagram'),
    ];
  }

  /// Resolve final list of allowed and disallowed packages for VpnService
  ({List<String> allowed, List<String> disallowed}) resolveForVpn({
    required bool licenseActive,
    String? singleTargetPackage,
  }) {
    switch (mode) {
      case AppFilterMode.all:
        return (allowed: <String>[], disallowed: <String>[]);

      case AppFilterMode.single:
        final resolved = TargetPackagePolicy.resolve(singleTargetPackage, licenseActive: licenseActive);
        return (allowed: [resolved], disallowed: <String>[]);

      case AppFilterMode.allowed:
        if (selectedPackages.isEmpty) {
          final resolved = TargetPackagePolicy.resolve(singleTargetPackage, licenseActive: licenseActive);
          return (allowed: [resolved], disallowed: <String>[]);
        }
        return (allowed: selectedPackages.toList(), disallowed: <String>[]);

      case AppFilterMode.disallowed:
        return (allowed: <String>[], disallowed: selectedPackages.toList());
    }
  }
}
