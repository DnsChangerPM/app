import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/release_info.dart';
import 'app_config.dart';

class VersionService {
  VersionService._();
  static final VersionService instance = VersionService._();

  static const String _killedKey = 'killed_releases';

  String currentVersion = '0.0.0';
  ReleaseInfo? latestRelease;

  /// Version-tags that the Cloudflare admin has marked as "killed".
  Set<String> killedVersions = {};

  /// Minimum version reported by the admin. Apps below this are forced to update.
  String minVersion = '0.0.0';

  Future<void> startBackgroundChecks() async {
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
    } catch (_) {}

    // Load persisted killed versions first so an offline start still blocks.
    await _loadKilledFromPrefs();
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final url = '${AppConfig.apiReleaseEndpoint}?version=$currentVersion';
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = (json['data'] as Map<String, dynamic>?) ?? json;

      final killed = (data['killed_versions'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [];
      killedVersions = killed.toSet();
      await _saveKilledToPrefs();

      final latestMap = data['latest'];
      if (latestMap is Map<String, dynamic>) {
        latestRelease = ReleaseInfo.fromGithubJson(latestMap);
      }

      final mv = data['min_version'];
      if (mv is String && mv.isNotEmpty) {
        minVersion = mv;
      }
    } catch (_) {
      // Offline: rely on cached killed-version list.
    }
  }

  bool get isKilled => killedVersions.contains(currentVersion);

  bool get updateRequired {
    if (isKilled) return true;
    if (minVersion.isNotEmpty) {
      if (ReleaseInfo.compareVersions(currentVersion, minVersion) < 0) {
        return true;
      }
    }
    return false;
  }

  Future<void> _loadKilledFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_killedKey);
      if (raw != null) {
        killedVersions =
            (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
      }
    } catch (_) {}
  }

  Future<void> _saveKilledToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_killedKey, jsonEncode(killedVersions.toList()));
    } catch (_) {}
  }
}
