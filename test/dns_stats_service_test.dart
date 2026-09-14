import 'package:dns_changer/services/dns_stats_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('records queries and maintains log history', () async {
    final stats = DnsStatsService.instance;
    await stats.init();
    stats.clearLogs();

    expect(stats.sessionQueries, 0);

    stats.recordQuery(
      domain: 'google.com',
      serverName: 'Cloudflare',
      latencyMs: 18,
    );

    expect(stats.sessionQueries, 1);
    expect(stats.recentLogs.length, 1);
    expect(stats.recentLogs.first.domain, 'google.com');
    expect(stats.recentLogs.first.serverName, 'Cloudflare');
    expect(stats.recentLogs.first.latencyMs, 18);
  });

  test('native events increment counters and loggingEnabled=false suppresses log', () async {
    final stats = DnsStatsService.instance;
    await stats.init();
    stats.clearLogs();
    stats.handleNativeQuery({
      'domain': 'example.com',
      'qtype': 'A',
      'serverIndex': 0,
      'latencyMs': 12,
    });
    expect(stats.sessionQueries, 1);
    expect(stats.recentLogs.first.domain, 'example.com');

    await stats.setLoggingEnabled(false);
    final before = stats.recentLogs.length;
    stats.handleNativeQuery({'domain': 'hidden.test', 'qtype': 'AAAA', 'serverIndex': 1, 'latencyMs': 9});
    expect(stats.recentLogs.length, before);
    await stats.setLoggingEnabled(true);
  });
}
