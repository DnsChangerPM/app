import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DnsSettingsService extends ChangeNotifier {
  static final DnsSettingsService instance = DnsSettingsService();

  static const String keyEnableIpv6 = 'dns_enable_ipv6';
  static const String keyAutoReconnect = 'dns_auto_reconnect';
  static const String keyAutoConnectOnBoot = 'dns_auto_connect_boot';
  static const String keyQueryTimeout = 'dns_query_timeout';
  static const String keyDnsLeakProtection = 'dns_leak_protection';
  static const String keyFallbackSecondary = 'dns_fallback_secondary';

  bool enableIpv6 = true;
  bool autoReconnect = true;
  bool autoConnectOnBoot = false;
  int queryTimeoutMs = 2500;
  bool dnsLeakProtection = true;
  bool fallbackSecondary = true;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enableIpv6 = prefs.getBool(keyEnableIpv6) ?? true;
    autoReconnect = prefs.getBool(keyAutoReconnect) ?? true;
    autoConnectOnBoot = prefs.getBool(keyAutoConnectOnBoot) ?? false;
    queryTimeoutMs = prefs.getInt(keyQueryTimeout) ?? 2500;
    dnsLeakProtection = prefs.getBool(keyDnsLeakProtection) ?? true;
    fallbackSecondary = prefs.getBool(keyFallbackSecondary) ?? true;
    notifyListeners();
  }

  Future<void> update({
    bool? newEnableIpv6,
    bool? newAutoReconnect,
    bool? newAutoConnectOnBoot,
    int? newQueryTimeoutMs,
    bool? newDnsLeakProtection,
    bool? newFallbackSecondary,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (newEnableIpv6 != null) {
      enableIpv6 = newEnableIpv6;
      await prefs.setBool(keyEnableIpv6, newEnableIpv6);
    }
    if (newAutoReconnect != null) {
      autoReconnect = newAutoReconnect;
      await prefs.setBool(keyAutoReconnect, newAutoReconnect);
    }
    if (newAutoConnectOnBoot != null) {
      autoConnectOnBoot = newAutoConnectOnBoot;
      await prefs.setBool(keyAutoConnectOnBoot, newAutoConnectOnBoot);
    }
    if (newQueryTimeoutMs != null) {
      queryTimeoutMs = newQueryTimeoutMs;
      await prefs.setInt(keyQueryTimeout, newQueryTimeoutMs);
    }
    if (newDnsLeakProtection != null) {
      dnsLeakProtection = newDnsLeakProtection;
      await prefs.setBool(keyDnsLeakProtection, newDnsLeakProtection);
    }
    if (newFallbackSecondary != null) {
      fallbackSecondary = newFallbackSecondary;
      await prefs.setBool(keyFallbackSecondary, newFallbackSecondary);
    }
    notifyListeners();
  }
}
