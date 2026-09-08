import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/license_info.dart';
import 'app_config.dart';

/// Client for the Cloudflare Worker license API.
class LicenseService {
  static const String _keyLicense = 'license_key';
  static const String _keyInfo = 'license_info';

  String? _licenseKey;
  LicenseInfo? _cachedInfo;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _licenseKey = prefs.getString(_keyLicense);
    final rawInfo = prefs.getString(_keyInfo);
    if (rawInfo != null) {
      try {
        _cachedInfo = LicenseInfo.fromJson(jsonDecode(rawInfo) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  String? get licenseKey => _licenseKey;
  LicenseInfo? get cachedInfo => _cachedInfo;

  /// Store a license key locally (does not validate yet).
  Future<void> setLicenseKey(String key) async {
    _licenseKey = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLicense, _licenseKey!);
  }

  Future<void> clear() async {
    _licenseKey = null;
    _cachedInfo = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLicense);
    await prefs.remove(_keyInfo);
  }

  Future<void> saveInfo(LicenseInfo info) async {
    _cachedInfo = info;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyInfo, jsonEncode(info.toJson()));
  }

  /// Calls `POST /api/client/license` to validate/activate a license.
  Future<LicenseInfo> validate({
    String? licenseKey,
    String? deviceName,
    String? deviceId,
  }) async {
    final key = licenseKey ?? _licenseKey;
    if (key == null || key.isEmpty) {
      return const LicenseInfo(valid: false, status: 'no_key', message: 'License key is empty');
    }

    final resp = await http
        .post(
          Uri.parse(AppConfig.apiLicenseEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'action': 'activate',
            'license_key': key,
            'device_name': deviceName,
            'device_id': deviceId,
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (resp.statusCode == 200) {
      final info = LicenseInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      await saveInfo(info);
      return info;
    }
    return LicenseInfo(
      valid: false,
      status: 'http_${resp.statusCode}',
      message: 'Server error (${resp.statusCode})',
    );
  }

  /// Lightweight check used to refresh device count / expiry without activation.
  Future<LicenseInfo> check({String? deviceId}) async {
    final key = _licenseKey;
    if (key == null || key.isEmpty) {
      return const LicenseInfo(valid: false, status: 'no_key');
    }
    try {
      final resp = await http
          .post(
            Uri.parse(AppConfig.apiLicenseEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'check',
              'license_key': key,
              'device_id': deviceId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final info = LicenseInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        await saveInfo(info);
        return info;
      }
    } catch (_) {}
    return _cachedInfo ?? const LicenseInfo(valid: false, status: 'unknown');
  }
}
