import 'dart:convert';

import 'package:dns_changer/services/custom_dns_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('validates IPv4, IPv6 and optional secondary without DNS lookups', () {
    for (final value in ['1.1.1.1', '192.168.1.1', '2606:4700:4700::1111']) {
      expect(CustomDnsService.addressError(value), isNull);
    }
    expect(CustomDnsService.addressError('', optional: true), isNull);
    for (final value in [
      '',
      '999.1.1.1',
      '1.1.1',
      'dns.google',
      'https://dns.google/dns-query',
      '1.1.1.1:853',
      '2001:::1',
      '::',
      '0.0.0.0',
      '224.0.0.1',
      'fe80::1%wlan0',
    ]) {
      expect(CustomDnsService.addressError(value), isNotNull, reason: value);
    }
  });

  test('saves and reloads named custom profiles with both addresses', () async {
    final saved = await CustomDnsService().save(
      name: '  My DNS  ',
      primary: ' 1.1.1.1 ',
      secondary: '2606:4700:4700::1001',
    );
    final reloaded = await CustomDnsService().load();
    expect(reloaded, hasLength(1));
    expect(reloaded.single.id, saved.id);
    expect(reloaded.single.name, 'My DNS');
    expect(reloaded.single.addresses, ['1.1.1.1', '2606:4700:4700::1001']);
    expect(reloaded.single.isCustom, isTrue);
    expect(reloaded.single.isPremium, isFalse);
  });

  test('edits keep a stable selection id and do not append duplicates',
      () async {
    final service = CustomDnsService();
    final first = await service.save(name: 'Old', primary: '1.1.1.1');
    await service.save(id: first.id, name: 'New', primary: '8.8.8.8');
    final profiles = await service.load();
    expect(profiles, hasLength(1));
    expect(profiles.single.id, first.id);
    expect(profiles.single.addresses, ['8.8.8.8']);
  });

  test('deduplicates the optional secondary address', () async {
    final profile = await CustomDnsService().save(
      name: 'My DNS',
      primary: '1.1.1.1',
      secondary: '1.1.1.1',
    );
    expect(profile.addresses, ['1.1.1.1']);
  });

  test('deleting the selected profile resets selection to a built-in DNS',
      () async {
    final service = CustomDnsService();
    final profile = await service.save(name: 'Mine', primary: '8.8.8.8');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_server', profile.id);
    await service.delete(profile.id);
    expect(await service.load(), isEmpty);
    expect(prefs.getString('selected_server'), 'cloudflare');
  });

  test('ignores corrupt records without losing valid profiles', () async {
    SharedPreferences.setMockInitialValues({
      CustomDnsService.storageKey: jsonEncode([
        {
          'id': 'custom_bad',
          'name': 'Bad',
          'addresses': ['not an IP']
        },
        {
          'id': 'custom_ok',
          'name': 'Home',
          'addresses': ['192.168.1.1'],
          'isPremium': true
        },
        null,
      ]),
    });
    final profiles = await CustomDnsService().load();
    expect(profiles, hasLength(1));
    expect(profiles.single.id, 'custom_ok');
    expect(profiles.single.isPremium, isFalse);
  });

  test('rejects invalid or empty profiles before writing preferences',
      () async {
    final service = CustomDnsService();
    await expectLater(
      service.save(name: '', primary: '8.8.8.8'),
      throwsFormatException,
    );
    await expectLater(
      service.save(name: 'Invalid', primary: 'https://example.com'),
      throwsFormatException,
    );
    expect(await service.load(), isEmpty);
  });
}
