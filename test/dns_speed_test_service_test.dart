import 'package:dns_changer/models/dns_server.dart';
import 'package:dns_changer/services/dns_speed_test_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pingAddress returns null on invalid or unreachable address', () async {
    final result = await DnsSpeedTestService.instance.pingAddress('999.999.999.999');
    expect(result, isNull);
  });

  test('cached pings management and clearing', () {
    final service = DnsSpeedTestService.instance;
    service.clearCache();
    expect(service.cachedPings, isEmpty);
  });
}
