import 'dart:convert';

import 'package:dns_changer/services/license_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  LicenseService serviceWith(MockClient client) {
    final service = LicenseService(client: client);
    addTearDown(() => service.clear());
    return service;
  }

  test('activates a valid license and decodes base64 DNS servers', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/client/license');
      expect(jsonDecode(request.body)['action'], 'activate');
      return http.Response(
        jsonEncode({
          'ok': true,
          'status': 'active',
          'message': 'License activated.',
          'data': {
            'valid': true,
            'status': 'active',
            'license_key': 'TEST-1234',
            'plan_name': 'Pro',
            'device_limit': 3,
            'device_count': 1,
            'expires_at': null,
            'dns_servers_b64': [
              base64.encode(utf8.encode('1.1.1.1')),
              base64.encode(utf8.encode('1.0.0.1')),
            ],
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final info = await serviceWith(client).validate(
      licenseKey: 'TEST-1234',
      deviceName: 'Android',
      deviceId: 'device-1',
    );

    expect(info.isActive, isTrue);
    expect(info.dnsServers, ['1.1.1.1', '1.0.0.1']);
    expect(info.deviceLimit, 3);
  });

  test('an unknown license key is reported as not_found, never a 404 error',
      () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'ok': false,
          'status': 'not_found',
          'message': 'Invalid license key.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final info = await serviceWith(client)
        .validate(licenseKey: 'WRONG-KEY', deviceId: 'device-1');

    expect(info.isActive, isFalse);
    expect(info.status, 'not_found');
    expect(info.message, 'Invalid license key.');
  });

  test('HTTP 404 with a Cloudflare HTML page means the server is missing',
      () async {
    final client = MockClient((request) async {
      return http.Response(
        '<html><body>404 Not Found</body></html>',
        404,
        headers: {'content-type': 'text/html'},
      );
    });

    final info = await serviceWith(client)
        .validate(licenseKey: 'KEY', deviceId: 'device-1');

    expect(info.isActive, isFalse);
    expect(info.status, 'server_not_found');
    expect(info.message, contains('404'));
  });

  test('HTTP 404 with a JSON body keeps the server-side status and message',
      () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'ok': false,
          'code': 'route_not_found',
          'status': 'endpoint_missing',
          'message': 'License API endpoint not found.',
        }),
        404,
        headers: {'content-type': 'application/json'},
      );
    });

    final info = await serviceWith(client)
        .validate(licenseKey: 'KEY', deviceId: 'device-1');

    expect(info.status, 'endpoint_missing');
    expect(info.message, 'License API endpoint not found.');
  });

  test('a non-JSON 500 becomes server_error instead of a crash', () async {
    final client = MockClient((request) async {
      return http.Response('Internal Server Error', 500);
    });

    final info = await serviceWith(client)
        .validate(licenseKey: 'KEY', deviceId: 'device-1');

    expect(info.isActive, isFalse);
    expect(info.status, 'server_error');
    expect(info.message, contains('500'));
  });

  test('a network failure is converted to unreachable with a clear message',
      () async {
    final client = MockClient(
        (request) async => throw http.ClientException('offline'));

    final info = await serviceWith(client)
        .validate(licenseKey: 'KEY', deviceId: 'device-1');

    expect(info.isActive, isFalse);
    expect(info.status, 'unreachable');
    expect(info.message, isNotEmpty);
  });

  test('health check accepts only the current Worker API version', () async {
    final current = MockClient((request) async {
      expect(request.url.path, '/api/public/health');
      return http.Response(
        jsonEncode({'ok': true, 'service': 'dns-changer', 'api': 2}),
        200,
      );
    });
    final currentHealth = await serviceWith(current).checkServerHealth();
    expect(currentHealth.ok, isTrue);
    expect(currentHealth.statusCode, 200);

    final old = MockClient((request) async {
      return http.Response(jsonEncode({'ok': true, 'api': 1}), 200);
    });
    final oldHealth = await serviceWith(old).checkServerHealth();
    expect(oldHealth.ok, isFalse);
    expect(oldHealth.message, contains('Deploy'));

    final missing = MockClient((request) async {
      return http.Response('<html>404</html>', 404);
    });
    final missingHealth = await serviceWith(missing).checkServerHealth();
    expect(missingHealth.ok, isFalse);
    expect(missingHealth.statusCode, 404);
  });

  test('check() keeps the cached license on server errors and does not throw',
      () async {
    final client = MockClient((request) async {
      return http.Response('<html>503</html>', 503);
    });

    final service = serviceWith(client);
    await service.setLicenseKey('CACHED-KEY');

    final info = await service.check(deviceId: 'device-1');
    expect(info.isActive, isFalse);
    expect(info.status, 'unknown');
  });
}
