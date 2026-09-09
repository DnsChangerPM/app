import 'package:dns_changer/models/dns_server.dart';
import 'package:dns_changer/services/dns_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('export and parse JSON backup of custom servers', () {
    const servers = [
      DnsServer(
        id: 'custom_1',
        name: 'My DNS Server',
        description: 'Test Description',
        addresses: ['1.1.1.1', '1.0.0.1'],
        isCustom: true,
      ),
      DnsServer(
        id: 'google',
        name: 'Google',
        description: 'Builtin',
        addresses: ['8.8.8.8'],
        isCustom: false,
      ),
    ];

    final jsonStr = DnsBackupService.instance.exportToJson(servers);
    expect(jsonStr, contains('My DNS Server'));
    expect(jsonStr, isNot(contains('Builtin')));

    final parsed = DnsBackupService.instance.parseImportJson(jsonStr);
    expect(parsed.length, 1);
    expect(parsed.first.name, 'My DNS Server');
    expect(parsed.first.addresses, ['1.1.1.1', '1.0.0.1']);
    expect(parsed.first.isCustom, isTrue);
  });

  test('parseImportJson throws FormatException on invalid input', () {
    expect(() => DnsBackupService.instance.parseImportJson('not json'), throwsFormatException);
  });
}
