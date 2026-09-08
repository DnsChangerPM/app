import 'package:dns_changer/models/vpn_status.dart';
import 'package:dns_changer/services/vpn_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_vpn_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only an established native tunnel is connected', () {
    for (final phase in VpnPhase.values) {
      final status = VpnStatus.fromMap({'state': phase.name, 'revision': 3});
      expect(status.isConnected, phase == VpnPhase.connected);
      expect(status.isPaused, phase == VpnPhase.paused);
    }
  });

  test('permission and transitional phases stay busy, paused remains resumable',
      () {
    for (final phase in [
      VpnPhase.requestingPermission,
      VpnPhase.connecting,
      VpnPhase.pausing,
      VpnPhase.stopping
    ]) {
      expect(VpnStatus(phase: phase).isBusy, isTrue);
    }
    expect(const VpnStatus(phase: VpnPhase.paused).hasSession, isTrue);
    expect(const VpnStatus(phase: VpnPhase.paused).isBusy, isFalse);
  });

  test('denied notification permission and native revisions are preserved', () {
    final status = VpnStatus.fromMap({
      'state': 'connected',
      'notificationsEnabled': false,
      'revision': 12,
    });
    expect(status.notificationsEnabled, isFalse);
    expect(status.revision, 12);
    expect(status.isConnected, isTrue);
  });

  test(
      'unknown status and error text never masquerade as connected or leak URLs',
      () {
    final status = VpnStatus.fromMap({'state': 'accepted', 'revision': 1});
    expect(status.phase, VpnPhase.error);
    expect(status.isConnected, isFalse);
    final failure = const VpnException('https://private.example/secret');
    expect(failure.toString(), isNot(contains('private.example')));
    expect(vpnErrorMessage('target_app_missing'), contains('برنامهٔ هدف'));
  });

  test('a start ACK is not connected until the native state changes', () async {
    final platform = FakeVpnPlatform()..autoConnect = false;
    platform.install();
    addTearDown(platform.dispose);
    final service = VpnServiceController();
    await service.start(['192.168.1.1'], allowedPackages: ['com.example.game']);
    expect((await service.getStatus()).phase, VpnPhase.connecting);
    expect(await service.isRunning(), isFalse);
    platform.setState('connected');
    expect(await service.isRunning(), isTrue);
    await service.pause();
    expect((await service.getStatus()).phase, VpnPhase.paused);
    await service.stop();
    expect((await service.getStatus()).phase, VpnPhase.disconnected);
    final start = platform.calls.singleWhere((call) => call.method == 'start');
    expect(start.arguments['addresses'], ['192.168.1.1']);
    expect(start.arguments['allowedPackages'], ['com.example.game']);
  });
}
