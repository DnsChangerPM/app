import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/license_info.dart';
import 'app_config.dart';

/// Result of a direct server health probe (used for diagnostics only).
class LicenseServerHealth {
  const LicenseServerHealth({
    required this.ok,
    this.statusCode,
    this.message,
  });

  /// `true` only when the Worker answered with the current API version
  /// (including the license activation route).
  final bool ok;
  final int? statusCode;
  final String? message;
}

/// Client for the Cloudflare Worker license API.
class LicenseService {
  LicenseService({http.Client? client}) : _client = client ?? http.Client();

  static const String _keyLicense = 'license_key';
  static const String _keyInfo = 'license_info';

  /// API version served by [AppConfig.apiHealthEndpoint]. The client only
  /// considers a health probe OK when the Worker answers with this version.
  static const int supportedApiVersion = 2;

  final http.Client _client;

  String? _licenseKey;
  LicenseInfo? _cachedInfo;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _licenseKey = prefs.getString(_keyLicense);
    final rawInfo = prefs.getString(_keyInfo);
    if (rawInfo != null) {
      try {
        _cachedInfo =
            LicenseInfo.fromJson(jsonDecode(rawInfo) as Map<String, dynamic>);
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

  /// The stable installation id sent with every activation/check. Persisted so
  /// a device ban from the admin panel keeps targeting this exact installation.
  Future<String> ensureDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null || id.isEmpty) {
      final rand = Random.secure();
      id = List.generate(
              16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString('device_id', id);
    }
    return id;
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
  ///
  /// Never throws for HTTP or network errors — every outcome is converted into
  /// a [LicenseInfo] whose `status` tells the UI exactly what happened
  /// (`not_found`, `limit_reached`, `server_not_found`, `unreachable`, …).
  Future<LicenseInfo> validate({
    String? licenseKey,
    String? deviceName,
    String? deviceId,
  }) async {
    final key = (licenseKey ?? _licenseKey)?.trim();
    if (key == null || key.isEmpty) {
      return const LicenseInfo(
        valid: false,
        status: 'no_key',
        message: 'کلید لایسنس وارد نشده است.',
      );
    }

    final http.Response resp;
    try {
      resp = await _client
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
    } catch (_) {
      return const LicenseInfo(
        valid: false,
        status: 'unreachable',
        message:
            'ارتباط با سرور لایسنس برقرار نشد؛ اینترنت را بررسی کنید و دوباره تلاش کنید.',
      );
    }

    final info = _parseResponse(resp);
    // A definitive server answer (active, not_found, limit_reached, …) is
    // persisted so the app never shows a stale activation after restart.
    if (resp.statusCode == 200 && info.status != 'unknown') {
      await saveInfo(info);
    }
    return info;
  }

  /// Lightweight check used to refresh device count / expiry without
  /// activation. A transient network/server problem keeps the cached
  /// activation so an existing user is never locked out by a short outage.
  Future<LicenseInfo> check({String? deviceId}) async {
    final key = _licenseKey;
    if (key == null || key.isEmpty) {
      return const LicenseInfo(valid: false, status: 'no_key');
    }
    try {
      final resp = await _client
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
        final info = _parseResponse(resp);
        await saveInfo(info);
        return info;
      }
      final json = _tryJson(resp.body);
      if (json != null) {
        return _fromErrorJson(json, resp.statusCode);
      }
    } catch (_) {}
    return _cachedInfo ?? const LicenseInfo(valid: false, status: 'unknown');
  }

  /// Probe the Worker health endpoint. Used by the UI to differentiate
  /// "wrong/old server" from "invalid key" without revealing the URL.
  Future<LicenseServerHealth> checkServerHealth() async {
    try {
      final resp = await _client
          .get(Uri.parse(AppConfig.apiHealthEndpoint))
          .timeout(const Duration(seconds: 6));
      final body = _tryJson(resp.body);
      if (resp.statusCode == 200 && body != null && body['ok'] == true) {
        final isCurrent = body['api'] == supportedApiVersion;
        return LicenseServerHealth(
          ok: isCurrent,
          statusCode: 200,
          message: isCurrent
              ? 'سرور لایسنس سالم است و مسیر فعال‌سازی فعال است. اگر باز هم خطا می‌بینید، '
                  'کلید را با کلیدی که در پنل همین سرور ساخته شده مقایسه کنید.'
              : 'سرور پاسخ می‌دهد ولی نسخه‌ی آن قدیمی است؛ سرور (Worker) را با آخرین کد Deploy کنید.',
        );
      }
      return LicenseServerHealth(
        ok: false,
        statusCode: resp.statusCode,
        message:
            'سرور پاسخ نداد (HTTP ${resp.statusCode}). سرور (Worker) را با آخرین کد Deploy کنید '
            'و اگر APK را خودتان ساخته‌اید با آدرس صحیح دوباره Build کنید.',
      );
    } catch (_) {
      return const LicenseServerHealth(
        ok: false,
        message:
            'به سرور لایسنس دسترسی نیست؛ اینترنت یا فیلترشکن را بررسی کنید و دوباره تلاش کنید.',
      );
    }
  }

  /// Parse any response from the license endpoint.
  ///
  /// The Worker returns HTTP 200 with `{ok:false, status:…}` for every
  /// application-level error (`not_found`, `limit_reached`, …). HTTP 404 with
  /// a JSON body means an older Worker/route mismatch; a non-JSON 404 is a
  /// Cloudflare edge "no route" answer — both are reported as a missing
  /// server instead of a cryptic "Server error (404)".
  LicenseInfo _parseResponse(http.Response resp) {
    final body = _tryJson(resp.body);
    if (body != null) {
      if (resp.statusCode == 200) {
        return LicenseInfo.fromJson(body);
      }
      return _fromErrorJson(body, resp.statusCode);
    }

    // Non-JSON answer (Cloudflare/proxy HTML or plain text).
    if (resp.statusCode == 404) {
      return const LicenseInfo(
        valid: false,
        status: 'server_not_found',
        message:
            'سرور لایسنس پیدا نشد (404). این نسخه با سرور صحیح ساخته نشده یا سرور قدیمی است؛ '
            'نسخه‌ی جدید برنامه را نصب کنید یا به سازنده اطلاع دهید.',
      );
    }
    return LicenseInfo(
      valid: false,
      status: 'server_error',
      message: 'خطای سرور (HTTP ${resp.statusCode})؛ کمی بعد دوباره تلاش کنید.',
    );
  }

  LicenseInfo _fromErrorJson(Map<String, dynamic> body, int statusCode) {
    final status = (body['status'] as String?) ?? 'http_$statusCode';
    final message = body['message'] as String?;
    return LicenseInfo(
      valid: false,
      status: status,
      message: message ??
          (status == 'not_found'
              ? 'لایسنس نامعتبر است؛ کلید را بررسی کنید یا با سازنده تماس بگیرید.'
              : 'خطای سرور (HTTP $statusCode)؛ کمی بعد دوباره تلاش کنید.'),
    );
  }

  Map<String, dynamic>? _tryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
