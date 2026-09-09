import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DnsQueryLogEntry {
  final String id;
  final DateTime timestamp;
  final String domain;
  final String queryType;
  final String serverName;
  final int latencyMs;
  final String status;

  const DnsQueryLogEntry({
    required this.id,
    required this.timestamp,
    required this.domain,
    required this.queryType,
    required this.serverName,
    required this.latencyMs,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'domain': domain,
        'queryType': queryType,
        'serverName': serverName,
        'latencyMs': latencyMs,
        'status': status,
      };
}

class DnsStatsService extends ChangeNotifier {
  static final DnsStatsService instance = DnsStatsService();

  static const String keyLoggingEnabled = 'dns_logging_enabled';
  static const String keyAllTimeQueries = 'all_time_queries_count';

  bool _loggingEnabled = true;
  int _sessionQueries = 0;
  int _allTimeQueries = 0;
  DateTime? _sessionStartTime;
  Timer? _durationTimer;
  Duration _sessionDuration = Duration.zero;

  final List<DnsQueryLogEntry> _recentLogs = [];
  static const int maxLogs = 200;

  bool get loggingEnabled => _loggingEnabled;
  int get sessionQueries => _sessionQueries;
  int get allTimeQueries => _allTimeQueries;
  Duration get sessionDuration => _sessionDuration;
  List<DnsQueryLogEntry> get recentLogs => List.unmodifiable(_recentLogs);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _loggingEnabled = prefs.getBool(keyLoggingEnabled) ?? true;
    _allTimeQueries = prefs.getInt(keyAllTimeQueries) ?? 0;
    notifyListeners();
  }

  Future<void> setLoggingEnabled(bool enabled) async {
    _loggingEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyLoggingEnabled, enabled);
    notifyListeners();
  }

  void onVpnConnected() {
    _sessionStartTime = DateTime.now();
    _sessionQueries = 0;
    _sessionDuration = Duration.zero;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sessionStartTime != null) {
        _sessionDuration = DateTime.now().difference(_sessionStartTime!);
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void onVpnDisconnected() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _sessionStartTime = null;
    notifyListeners();
  }

  void recordQuery({
    required String domain,
    String queryType = 'A',
    required String serverName,
    int latencyMs = 25,
    String status = 'Resolved',
  }) {
    _sessionQueries++;
    _allTimeQueries++;

    if (_loggingEnabled) {
      final entry = DnsQueryLogEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        timestamp: DateTime.now(),
        domain: domain,
        queryType: queryType,
        serverName: serverName,
        latencyMs: latencyMs,
        status: status,
      );
      _recentLogs.insert(0, entry);
      if (_recentLogs.length > maxLogs) {
        _recentLogs.removeLast();
      }
    }

    _persistAllTimeQueries();
    notifyListeners();
  }

  Future<void> _persistAllTimeQueries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(keyAllTimeQueries, _allTimeQueries);
    } catch (_) {}
  }

  void clearLogs() {
    _recentLogs.clear();
    _sessionQueries = 0;
    notifyListeners();
  }
}
