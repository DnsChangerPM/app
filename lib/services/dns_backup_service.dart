import 'dart:convert';
import 'package:flutter/services.dart';

import '../models/dns_server.dart';
import 'custom_dns_service.dart';

class DnsBackupService {
  static final DnsBackupService instance = DnsBackupService();

  /// Export custom DNS servers to formatted JSON string
  String exportToJson(List<DnsServer> servers) {
    final list = servers.where((s) => s.isCustom).map((s) => s.toJson()).toList();
    final data = {
      'app': 'DNS Changer',
      'version': '1.0',
      'exported_at': DateTime.now().toIso8601String(),
      'custom_servers': list,
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Copy export JSON to clipboard
  Future<void> copyToClipboard(List<DnsServer> servers) async {
    final jsonStr = exportToJson(servers);
    await Clipboard.setData(ClipboardData(text: jsonStr));
  }

  /// Parse and import custom DNS profiles from JSON string
  List<DnsServer> parseImportJson(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr.trim());
      List<dynamic> items = [];
      if (decoded is List) {
        items = decoded;
      } else if (decoded is Map<String, dynamic>) {
        if (decoded.containsKey('custom_servers') && decoded['custom_servers'] is List) {
          items = decoded['custom_servers'] as List;
        } else if (decoded.containsKey('servers') && decoded['servers'] is List) {
          items = decoded['servers'] as List;
        }
      }

      final imported = <DnsServer>[];
      for (final item in items) {
        if (item is Map<String, dynamic>) {
          final server = DnsServer.fromJson(item).copyWith(isCustom: true);
          if (server.addresses.isNotEmpty && server.name.isNotEmpty) {
            imported.add(server);
          }
        }
      }
      return imported;
    } catch (_) {
      throw const FormatException('فرمت فایل پشتیبان معتبر نیست.');
    }
  }

  /// Import profiles and save them to storage via CustomDnsService
  Future<int> importAndSave(String jsonStr) async {
    final parsed = parseImportJson(jsonStr);
    if (parsed.isEmpty) throw const FormatException('هیچ دی‌ان‌اس معتبری در متن ورودی یافت نشد.');

    final customService = CustomDnsService();
    int count = 0;
    for (final s in parsed) {
      final primary = s.addresses.first;
      final secondary = s.addresses.length > 1 ? s.addresses[1] : null;
      await customService.save(
        name: s.name,
        primary: primary,
        secondary: secondary,
      );
      count++;
    }
    return count;
  }
}
