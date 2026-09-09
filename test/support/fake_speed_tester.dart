import 'package:dns_changer/models/dns_server.dart';
import 'package:dns_changer/services/dns_speed_test_service.dart';

/// A speed test that never touches the network, so widget tests do not leave
/// pending socket/timeout timers behind.
class FakeSpeedTestService extends DnsSpeedTestService {
  @override
  Future<int?> pingServer(
    DnsServer server, {
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    return null;
  }

  @override
  Future<DnsServer?> findFastest(List<DnsServer> servers) async {
    return servers.isEmpty ? null : servers.first;
  }
}
