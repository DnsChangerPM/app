import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/release_info.dart';
import 'app_config.dart';

/// Checks GitHub independently of the admin policy and remembers mandatory
/// updates across restarts, failed requests and offline launches.
class VersionService extends ChangeNotifier {
  VersionService({
    http.Client? client,
    Future<String> Function()? versionLoader,
  })  : _client = client ?? http.Client(),
        _versionLoader = versionLoader ?? _platformVersion;

  static final VersionService instance = VersionService();
  static const _cacheKey = 'release_policy_v1';
  static const _legacyKilledKey = 'killed_releases';

  final http.Client _client;
  final Future<String> Function() _versionLoader;
  Future<void>? _initializing;
  Future<void>? _refreshing;
  bool _disposed = false;
  bool _adminHasReleaseResponse = false;

  String currentVersion = '0.0.0';
  ReleaseInfo? latestRelease;
  Set<String> killedVersions = {};
  String minVersion = '0.0.0';
  bool initialized = false;
  bool checking = false;
  bool lastCheckSucceeded = false;

  static Future<String> _platformVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      currentVersion = await _versionLoader();
    } catch (_) {
      // PackageInfo is available on Android. Keep the gate closed if it fails;
      // retrying should never claim an unknown installed version is current.
      _initializing = null;
      _notify();
      return;
    }
    await _loadPolicy();
    _notify();
    await refresh();
    initialized = true;
    _notify();
  }

  /// Single-flight: a settings check and a resume check share the same request.
  Future<void> refresh() {
    if (_disposed) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    checking = true;
    _adminHasReleaseResponse = false;
    _notify();
    try {
      final results = await Future.wait([
        _fetchGithubRelease(),
        _fetchAdminPolicy(),
      ]);
      // A policy-only Worker response does not prove GitHub was reachable.
      lastCheckSucceeded = results.first || _adminHasReleaseResponse;
      if (results.any((success) => success)) await _savePolicy();
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<bool> _fetchGithubRelease() async {
    try {
      final response = await _client.get(
        Uri.parse(AppConfig.githubReleaseEndpoint),
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'DNS-Changer-Android',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ).timeout(const Duration(seconds: 10));
      // A repository without releases is not an update or a network failure.
      if (response.statusCode == 404) return true;
      if (response.statusCode != 200) return false;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['tag_name'] is! String) return false;
      _acceptRelease(ReleaseInfo.fromGithubJson(json), authoritative: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _fetchAdminPolicy() async {
    try {
      final uri = Uri.parse(AppConfig.apiReleaseEndpoint)
          .replace(queryParameters: {'version': currentVersion});
      final response =
          await _client.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['ok'] == false) return false;
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final killed = data['killed_versions'];
      if (killed is List) {
        killedVersions = killed
            .whereType<String>()
            .where(ReleaseInfo.isValidVersion)
            .toSet();
      }
      final minimum = data['min_version'];
      if (minimum is String && ReleaseInfo.isValidVersion(minimum)) {
        minVersion = minimum;
      }
      final latest = data['latest'];
      if (latest is Map<String, dynamic>) {
        try {
          final release = ReleaseInfo.fromGithubJson(latest);
          _adminHasReleaseResponse = latest['tag_name'] is String &&
              ReleaseInfo.isValidVersion(release.tag);
          _acceptRelease(release);
        } catch (_) {
          // An invalid release must not discard an otherwise valid policy.
        }
      }
      return killed is List || minimum is String || _adminHasReleaseResponse;
    } catch (_) {
      return false;
    }
  }

  void _acceptRelease(ReleaseInfo release, {bool authoritative = false}) {
    if (!release.hasApk) return;
    final previous = latestRelease;
    final comparison = previous == null
        ? 1
        : ReleaseInfo.compareVersions(release.tag, previous.tag);
    if (comparison > 0 || (comparison == 0 && authoritative)) {
      latestRelease = release;
    }
    // Never downgrade a known release. For equal tags, prefer direct GitHub
    // metadata over a stale Worker entry (URL, size and digest may have changed).
  }

  bool get isKilled => killedVersions.any(
        (version) => ReleaseInfo.compareVersions(version, currentVersion) == 0,
      );

  bool get updateRequired =>
      isKilled ||
      ReleaseInfo.compareVersions(currentVersion, minVersion) < 0 ||
      (latestRelease != null &&
          ReleaseInfo.compareVersions(currentVersion, latestRelease!.tag) < 0);

  /// A policy may require a version whose APK has not been uploaded yet.
  /// Do not offer the old APK (or a version below the required minimum).
  ReleaseInfo? get availableUpdate {
    final release = latestRelease;
    if (release == null ||
        !release.hasApk ||
        ReleaseInfo.compareVersions(release.tag, currentVersion) <= 0 ||
        ReleaseInfo.compareVersions(release.tag, minVersion) < 0 ||
        killedVersions.any(
          (v) => ReleaseInfo.compareVersions(release.tag, v) == 0,
        )) {
      return null;
    }
    return release;
  }

  Future<void> _loadPolicy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_legacyKilledKey);
      if (legacy != null) {
        try {
          killedVersions = (jsonDecode(legacy) as List)
              .whereType<String>()
              .where(ReleaseInfo.isValidVersion)
              .toSet();
        } catch (_) {
          // A bad legacy record must not prevent reading the newer full cache.
        }
      }
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final minimum = data['min_version'];
      if (minimum is String && ReleaseInfo.isValidVersion(minimum)) {
        minVersion = minimum;
      }
      if (data['killed_versions'] is List) {
        killedVersions = (data['killed_versions'] as List)
            .whereType<String>()
            .where(ReleaseInfo.isValidVersion)
            .toSet();
      }
      if (data['latest'] is Map<String, dynamic>) {
        _acceptRelease(ReleaseInfo.fromGithubJson(data['latest']));
      }
    } catch (_) {
      // A malformed cache must not crash startup. The online check can repair it.
    }
  }

  Future<void> _savePolicy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'min_version': minVersion,
          'killed_versions': killedVersions.toList(),
          'latest': latestRelease?.toJson(),
        }),
      );
      await prefs.remove(_legacyKilledKey);
    } catch (_) {
      // The in-memory policy still applies if local storage is unavailable.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}
