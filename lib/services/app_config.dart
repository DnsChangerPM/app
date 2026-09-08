import 'package:shared_preferences/shared_preferences.dart';

/// Central place for runtime configuration (API base URL, GitHub repo).
/// Override `API_BASE_URL` in the Cloudflare admin panel "App Settings" or via
/// `--dart-define` at build time:
///   flutter build apk --dart-define=API_BASE_URL=https://dns.xxx.workers.dev
class AppConfig {
  static const String githubRepo = 'DnsChangerPM/app';

  static String _apiBaseUrl = const String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://dns-changer.dnschangerpm.workers.dev',
  );

  static String get apiBaseUrl => _apiBaseUrl;

  static const String _keyApiBase = 'config_api_base_url';

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_keyApiBase);
    if (stored != null && stored.trim().isNotEmpty) {
      _apiBaseUrl = stored.trim();
    }
  }

  static Future<void> setApiBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _apiBaseUrl = url.trim().isEmpty
        ? const String.fromEnvironment('API_BASE_URL',
            defaultValue: 'https://dns-changer.dnschangerpm.workers.dev')
        : url.trim();
    await prefs.setString(_keyApiBase, _apiBaseUrl);
  }

  static String get apiLicenseEndpoint => '$_apiBaseUrl/api/client/license';
  static String get apiReleaseEndpoint => '$_apiBaseUrl/api/client/release';
}
