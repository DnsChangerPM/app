import 'dart:convert';

/// Holds the license state returned by the Cloudflare Worker.
class LicenseInfo {
  final bool valid;
  final String status; // active | expired | revoked | banned | not_found
  final String? licenseKey;
  final String? planName;
  final int? deviceLimit;
  final int? deviceCount;
  final DateTime? expiresAt;
  final List<String> dnsServers;
  final String? message;

  const LicenseInfo({
    required this.valid,
    required this.status,
    this.licenseKey,
    this.planName,
    this.deviceLimit,
    this.deviceCount,
    this.expiresAt,
    this.dnsServers = const [],
    this.message,
  });

  bool get isActive => valid && status == 'active';

  factory LicenseInfo.fromJson(Map<String, dynamic> json) {
    final data = (json['data'] as Map<String, dynamic>?) ?? json;
    final expiresRaw = data['expires_at'];
    return LicenseInfo(
      valid: json['ok'] == true || data['valid'] == true,
      status: (data['status'] as String?) ??
          (json['status'] as String?) ??
          'unknown',
      licenseKey: data['license_key'] as String?,
      planName: data['plan_name'] as String?,
      deviceLimit: data['device_limit'] as int?,
      deviceCount: data['device_count'] as int?,
      expiresAt: expiresRaw is String ? DateTime.tryParse(expiresRaw) : null,
      dnsServers: _parseDnsServers(data),
      message: json['message'] as String? ?? data['message'] as String?,
    );
  }

  /// The worker encodes subscription DNS addresses as base64 for transport.
  /// This is not encryption; privacy in the UI is handled by the server widgets.
  /// Support both plain and encoded forms.
  static List<String> _parseDnsServers(Map<String, dynamic> data) {
    final plain = data['dns_servers'] as List?;
    if (plain != null) return plain.map((e) => e.toString()).toList();

    final encoded = data['dns_servers_b64'] as List?;
    if (encoded != null) {
      final out = <String>[];
      for (final e in encoded) {
        try {
          out.add(utf8.decode(base64.decode(e.toString())));
        } catch (_) {
          out.add(e.toString());
        }
      }
      return out;
    }
    return const [];
  }

  Map<String, dynamic> toJson() => {
        'valid': valid,
        'status': status,
        'license_key': licenseKey,
        'plan_name': planName,
        'device_limit': deviceLimit,
        'device_count': deviceCount,
        'expires_at': expiresAt?.toIso8601String(),
        'dns_servers': dnsServers,
        'message': message,
      };
}
