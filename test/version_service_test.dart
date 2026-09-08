import 'dart:async';
import 'dart:convert';

import 'package:dns_changer/services/version_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'release_info_test.dart' show releaseJson;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  VersionService service({
    String current = '1.0.1',
    Map<String, dynamic>? github,
    Map<String, dynamic>? policy,
    bool offline = false,
  }) {
    final versions = VersionService(
      versionLoader: () async => current,
      client: MockClient((request) async {
        if (offline) throw http.ClientException('offline');
        final isGithub = request.url.host == 'api.github.com';
        final data = isGithub ? github : policy;
        return http.Response(jsonEncode(data ?? {}), data == null ? 503 : 200);
      }),
    );
    addTearDown(versions.dispose);
    return versions;
  }

  test('a newer GitHub APK forces an update without any Worker config',
      () async {
    final versions = service(github: releaseJson('1.0.2'));
    await versions.initialize();
    expect(versions.initialized, isTrue);
    expect(versions.lastCheckSucceeded, isTrue);
    expect(versions.updateRequired, isTrue);
    expect(versions.availableUpdate?.tag, 'v1.0.2');
  });

  test('same or older versions never force an update', () async {
    for (final version in ['1.0.0', '1.0.1']) {
      final versions = service(github: releaseJson(version));
      await versions.initialize();
      expect(versions.updateRequired, isFalse);
      expect(versions.availableUpdate, isNull);
    }
  });

  test('publishing release metadata before its APK does not lock users out',
      () async {
    final versions = service(github: releaseJson('1.1.0', apk: false));
    await versions.initialize();
    expect(versions.updateRequired, isFalse);
  });

  test('mandatory release and download URL survive repeated offline launches',
      () async {
    final online = service(github: releaseJson('1.1.0'));
    await online.initialize();
    for (var i = 0; i < 2; i++) {
      final offline = service(offline: true);
      await offline.initialize();
      expect(offline.updateRequired, isTrue);
      expect(offline.availableUpdate?.apkUrl, online.availableUpdate?.apkUrl);
      expect(offline.availableUpdate?.apkSize, 16);
      expect(offline.lastCheckSucceeded, isFalse);
    }
    final updated = service(current: '1.1.0', offline: true);
    await updated.initialize();
    expect(updated.updateRequired, isFalse);
  });

  test('minimum version is cached even without an APK', () async {
    final online = service(policy: {
      'ok': true,
      'data': {'min_version': '1.2.0', 'killed_versions': []},
    });
    await online.initialize();
    final offline = service(offline: true);
    await offline.initialize();
    expect(offline.updateRequired, isTrue);
    expect(offline.minVersion, '1.2.0');
    expect(offline.availableUpdate, isNull);
  });

  test('normalizes explicit killed versions and migrates legacy policy',
      () async {
    SharedPreferences.setMockInitialValues({
      'killed_releases': jsonEncode(['v1.0.1']),
    });
    final offline = service(offline: true);
    await offline.initialize();
    expect(offline.isKilled, isTrue);
    expect(offline.updateRequired, isTrue);
  });

  test('a stale Worker response cannot replace the newer GitHub release',
      () async {
    final versions = service(
      github: releaseJson('1.3.0'),
      policy: {
        'data': {
          'latest': releaseJson('1.2.0'),
          'min_version': '1.2.0',
          'killed_versions': [],
        },
      },
    );
    await versions.initialize();
    expect(versions.availableUpdate?.tag, 'v1.3.0');
  });

  test('does not offer an APK below the minimum or an explicitly killed APK',
      () async {
    final belowMinimum = service(github: releaseJson('1.1.0'), policy: {
      'min_version': '1.2.0',
      'killed_versions': [],
    });
    await belowMinimum.initialize();
    expect(belowMinimum.updateRequired, isTrue);
    expect(belowMinimum.availableUpdate, isNull);
    final killed = service(github: releaseJson('1.2.0'), policy: {
      'min_version': '1.0.0',
      'killed_versions': ['v1.2.0'],
    });
    await killed.initialize();
    expect(killed.availableUpdate, isNull);
  });

  test('direct GitHub asset metadata wins over the Worker for equal tags',
      () async {
    final github = releaseJson('1.2.0');
    final hash = List.filled(64, 'a').join();
    (github['assets'] as List).first['digest'] = 'sha256:$hash';
    final versions = service(github: github, policy: {
      'latest': releaseJson('1.2.0'),
      'min_version': '1.0.0',
      'killed_versions': [],
    });
    await versions.initialize();
    expect(versions.availableUpdate?.sha256, hash);
  });

  test('a bad legacy entry cannot hide the current offline policy', () async {
    SharedPreferences.setMockInitialValues({
      'killed_releases': '{broken',
      'release_policy_v1': jsonEncode({
        'min_version': '1.2.0',
        'killed_versions': [],
        'latest': releaseJson('1.2.0'),
      }),
    });
    final versions = service(offline: true);
    await versions.initialize();
    expect(versions.updateRequired, isTrue);
    expect(versions.availableUpdate?.tag, 'v1.2.0');
  });

  test('valid minimum policy is saved even if release metadata is malformed',
      () async {
    final versions = service(policy: {
      'min_version': '1.2.0',
      'killed_versions': [],
      'latest': {'assets': 'invalid'},
    });
    await versions.initialize();
    expect(versions.updateRequired, isTrue);
    expect(versions.lastCheckSucceeded, isFalse);
    final offline = service(offline: true);
    await offline.initialize();
    expect(offline.updateRequired, isTrue);
  });

  test('corrupt cache and failed requests do not crash startup', () async {
    SharedPreferences.setMockInitialValues({'release_policy_v1': '{invalid'});
    final versions = service(offline: true);
    await versions.initialize();
    expect(versions.initialized, isTrue);
    expect(versions.updateRequired, isFalse);
    expect(versions.lastCheckSucceeded, isFalse);
  });

  test('concurrent refreshes use one request per source and notify listeners',
      () async {
    var requests = 0;
    Completer<void>? pending;
    final versions = VersionService(
      versionLoader: () async => '1.0.1',
      client: MockClient((request) async {
        requests++;
        final gate = pending;
        if (gate != null) await gate.future;
        return http.Response('{}', 503);
      }),
    );
    addTearDown(versions.dispose);
    await versions.initialize();
    pending = Completer<void>();
    var notifications = 0;
    versions.addListener(() => notifications++);
    final first = versions.refresh();
    final second = versions.refresh();
    expect(identical(first, second), isTrue);
    pending.complete();
    await Future.wait([first, second]);
    expect(requests, 4);
    expect(notifications, greaterThanOrEqualTo(2));
  });

  test('a failed platform version lookup can be retried', () async {
    var attempts = 0;
    final versions = VersionService(
      versionLoader: () async {
        if (attempts++ == 0) throw StateError('unavailable');
        return '1.0.1';
      },
      client: MockClient((_) async => http.Response('{}', 404)),
    );
    addTearDown(versions.dispose);
    await versions.initialize();
    expect(versions.initialized, isFalse);
    await versions.initialize();
    expect(versions.initialized, isTrue);
  });
}
