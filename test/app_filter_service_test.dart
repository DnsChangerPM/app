import 'package:dns_changer/models/app_info.dart';
import 'package:dns_changer/services/app_filter_service.dart';
import 'package:dns_changer/services/target_package_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default mode is all apps with empty allowed and disallowed lists', () async {
    final service = AppFilterService();
    await service.load();
    expect(service.mode, AppFilterMode.all);

    final resolved = service.resolveForVpn(licenseActive: false);
    expect(resolved.allowed, isEmpty);
    expect(resolved.disallowed, isEmpty);
  });

  test('single mode resolves target package based on license state', () async {
    final service = AppFilterService();
    service.mode = AppFilterMode.single;

    final unlicensed = service.resolveForVpn(
      licenseActive: false,
      singleTargetPackage: 'com.other.game',
    );
    expect(unlicensed.allowed, [TargetPackagePolicy.defaultTargetPackage]);

    final licensed = service.resolveForVpn(
      licenseActive: true,
      singleTargetPackage: 'com.other.game',
    );
    expect(licensed.allowed, ['com.other.game']);
  });

  test('allowed mode returns selected packages whitelist', () async {
    final service = AppFilterService();
    service.mode = AppFilterMode.allowed;
    service.selectedPackages = {'com.app.a', 'com.app.b'};

    final resolved = service.resolveForVpn(licenseActive: true);
    expect(resolved.allowed, containsAll(['com.app.a', 'com.app.b']));
    expect(resolved.disallowed, isEmpty);
  });

  test('disallowed mode returns selected packages blacklist (bypass)', () async {
    final service = AppFilterService();
    service.mode = AppFilterMode.disallowed;
    service.selectedPackages = {'com.bank.app', 'com.bypass.app'};

    final resolved = service.resolveForVpn(licenseActive: true);
    expect(resolved.allowed, isEmpty);
    expect(resolved.disallowed, containsAll(['com.bank.app', 'com.bypass.app']));
  });
}
