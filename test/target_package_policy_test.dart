import 'package:dns_changer/services/target_package_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('free installs are locked to the default package', () {
    expect(
      TargetPackagePolicy.resolve('com.other.app', licenseActive: false),
      TargetPackagePolicy.defaultTargetPackage,
    );
    expect(
      TargetPackagePolicy.resolve(null, licenseActive: false),
      TargetPackagePolicy.defaultTargetPackage,
    );
  });

  test('an active license unlocks a custom package', () {
    expect(
      TargetPackagePolicy.resolve('com.other.app', licenseActive: true),
      'com.other.app',
    );
  });

  test('invalid or empty values fall back to the default', () {
    expect(TargetPackagePolicy.resolve('  ', licenseActive: true),
        TargetPackagePolicy.defaultTargetPackage);
    expect(TargetPackagePolicy.resolve('not a package', licenseActive: true),
        TargetPackagePolicy.defaultTargetPackage);
    expect(TargetPackagePolicy.isValidPackage('com.tencent.ig'), isTrue);
    expect(TargetPackagePolicy.isValidPackage('tencent'), isFalse);
  });
}
