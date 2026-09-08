import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/dns_server.dart';

/// User-owned DNS profiles. Only literal IPv4/IPv6 addresses, on DNS port 53.
class CustomDnsService {
  static const storageKey = 'custom_dns_servers_v1';

  static String? addressError(String? value, {bool optional = false}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return optional ? null : 'آدرس DNS را وارد کنید';
    final ip = InternetAddress.tryParse(text);
    if (ip == null || text.contains('%')) {
      return 'یک آدرس IPv4 یا IPv6 معتبر وارد کنید؛ نه لینک یا نام دامنه';
    }
    if (ip.rawAddress.every((byte) => byte == 0) || ip.isMulticast) {
      return 'این آدرس قابل استفاده به‌عنوان DNS نیست';
    }
    return null;
  }

  Future<List<DnsServer>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return [];
    final profiles = <DnsServer>[];
    try {
      final items = jsonDecode(raw) as List;
      final seen = <String>{};
      for (final item in items) {
        // Skip an invalid record without losing the other saved profiles.
        try {
          final data = item as Map<String, dynamic>;
          final id = data['id'] as String;
          final name = (data['name'] as String).trim();
          final addresses = (data['addresses'] as List).cast<String>();
          if (!id.startsWith('custom_') || name.isEmpty || !seen.add(id)) {
            continue;
          }
          profiles.add(_profile(id, name, addresses));
        } catch (_) {}
      }
    } catch (_) {}
    return profiles;
  }

  Future<DnsServer> save({
    String? id,
    required String name,
    required String primary,
    String secondary = '',
  }) async {
    final profile = _profile(
      id ?? 'custom_${DateTime.now().microsecondsSinceEpoch}',
      name.trim(),
      [primary.trim(), if (secondary.trim().isNotEmpty) secondary.trim()],
    );
    final profiles = await load();
    final index = profiles.indexWhere((server) => server.id == profile.id);
    if (index < 0) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    await _persist(profiles);
    return profile;
  }

  Future<void> delete(String id) async {
    final profiles = await load();
    profiles.removeWhere((profile) => profile.id == id);
    await _persist(profiles);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('selected_server') == id) {
      await prefs.setString('selected_server', 'cloudflare');
    }
  }

  DnsServer _profile(String id, String name, List<String> addresses) {
    if (!id.startsWith('custom_') ||
        name.isEmpty ||
        name.length > 60 ||
        addresses.isEmpty ||
        addresses.length > 2 ||
        addresses.any((address) => addressError(address) != null)) {
      throw const FormatException('Invalid custom DNS profile');
    }
    final normalized = addresses
        .map((address) => InternetAddress.tryParse(address.trim())!.address)
        .toSet()
        .toList();
    return DnsServer(
      id: id,
      name: name,
      description: 'DNS شخصی',
      addresses: List.unmodifiable(normalized),
      isCustom: true,
    );
  }

  Future<void> _persist(List<DnsServer> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      storageKey,
      jsonEncode([
        for (final profile in profiles)
          {
            'id': profile.id,
            'name': profile.name,
            'addresses': profile.addresses,
          },
      ]),
    );
    if (!saved) throw StateError('Could not save custom DNS');
  }
}
