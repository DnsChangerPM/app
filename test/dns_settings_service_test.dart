import 'package:dns_changer/services/dns_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads defaults and persists changes', () async {
    final settings = DnsSettingsService.instance;
    await settings.load();

    expect(settings.enableIpv6, isTrue);
    expect(settings.autoReconnect, isTrue);
    expect(settings.autoConnectOnBoot, isFalse);

    await settings.update(
      newEnableIpv6: false,
      newAutoConnectOnBoot: true,
      newQueryTimeoutMs: 4000,
    );

    expect(settings.enableIpv6, isFalse);
    expect(settings.autoConnectOnBoot, isTrue);
    expect(settings.queryTimeoutMs, 4000);
  });
}
