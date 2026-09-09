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
}
