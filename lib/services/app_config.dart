import 'package:shared_preferences/shared_preferences.dart';

/// Build-time configuration only. Backend addresses are not user settings.
/// Override with --dart-define=API_BASE_URL=https://YOUR.workers.dev.
/// Removing a URL from the UI does not make an endpoint embedded in an APK secret.
class AppConfig {
  static const String githubRepo = 'DnsChangerPM/app';

  /// The bundled fallback is only a documented placeholder — the real Worker
  /// deployed from `cloudflare/` gets a URL like
  /// `https://dns-changer-admin.<account>.workers.dev`. Release builds MUST be
  /// compiled with `--dart-define=API_BASE_URL=...` (CI enforces this and
  /// verifies `/api/public/health` before publishing). The app itself only
  /// checks whether the endpoint answers; it never shows this URL to users.
  static const String bundledFallbackApiBaseUrl =
      'https://dns-changer.dnschangerpm.workers.dev';
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: bundledFallbackApiBaseUrl,
  );

  static const String telegramChannel = 'https://t.me/DnsChangerPM';
  static const String telegramGroup = 'https://t.me/DnsChangerPMGP';
  static const String telegramCreator = 'https://t.me/AnishtayiN';

  static Future<void> load() async {
    // Retire the old editable endpoint, including overrides saved by old builds.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('config_api_base_url');
  }

  static String get _apiBase => apiBaseUrl.replaceFirst(RegExp(r'/+$'), '');
  static String get apiLicenseEndpoint => '$_apiBase/api/client/license';
  static String get apiReleaseEndpoint => '$_apiBase/api/client/release';
  static String get apiHealthEndpoint => '$_apiBase/api/public/health';
  static String get githubReleaseEndpoint =>
      'https://api.github.com/repos/$githubRepo/releases/latest';
}
