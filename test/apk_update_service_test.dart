import 'dart:async';
import 'dart:io';

import 'package:dns_changer/models/release_info.dart';
import 'package:dns_changer/services/apk_update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/updater');
  const release = ReleaseInfo(
    tag: 'v1.0.2',
    name: 'Update',
    apkUrl: 'https://github.com/update.apk',
    apkSize: 16,
  );
  final bytes = [0x50, 0x4b, 3, 4, ...List.filled(12, 1)];
  late Directory directory;
  late List<MethodCall> nativeCalls;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dns-updater-test-');
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'getUpdateDirectory') return directory.path;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  ApkUpdateService updater(MockClient client) {
    final service =
        ApkUpdateService(clientFactory: () => client, channel: channel);
    addTearDown(service.dispose);
    return service;
  }

  test('streams real 0–100 progress and atomically saves the complete APK',
      () async {
    final body = StreamController<List<int>>();
    final connected = Completer<void>();
    final halfway = Completer<void>();
    final service = updater(MockClient.streaming((request, _) async {
      connected.complete();
      return http.StreamedResponse(body.stream, 200, contentLength: 16);
    }));
    final progress = <int>[];
    final download = service.download(release, onProgress: (percent) {
      progress.add(percent);
      if (percent == 50) halfway.complete();
    });
    await connected.future;
    body.add(bytes.sublist(0, 8));
    await halfway.future;
    expect(progress, [0, 50]);
    body.add(bytes.sublist(8));
    await body.close();
    final path = await download;
    expect(progress, [0, 50, 99, 100]);
    expect(await File(path).readAsBytes(), bytes);
    expect(await File('${directory.path}/update.apk.part').exists(), isFalse);
    expect(nativeCalls.where((call) => call.method == 'installApk'), isEmpty);
    await service.install(path, sha256: 'abc');
    expect(nativeCalls.last.method, 'installApk');
    expect(nativeCalls.last.arguments, {'path': path, 'sha256': 'abc'});
  });

  test('uses GitHub asset size when Content-Length is absent', () async {
    final service = updater(MockClient.streaming(
        (_, __) async => http.StreamedResponse(Stream.value(bytes), 200)));
    final progress = <int>[];
    await service.download(release, onProgress: progress.add);
    expect(progress.first, 0);
    expect(progress.last, 100);
  });

  test('truncated downloads are removed and never report 100 percent',
      () async {
    final service = updater(MockClient.streaming((_, __) async =>
        http.StreamedResponse(Stream.value(bytes.sublist(0, 8)), 200)));
    final progress = <int>[];
    await expectLater(service.download(release, onProgress: progress.add),
        throwsA(isA<UpdateException>()));
    expect(progress, isNot(contains(100)));
    expect(await directory.list().toList(), isEmpty);
  });

  test('rejects a non-APK error page even with the expected byte count',
      () async {
    final service = updater(MockClient.streaming((_, __) async =>
        http.StreamedResponse(Stream.value(List.filled(16, 60)), 200,
            contentLength: 16)));
    await expectLater(service.download(release, onProgress: (_) {}),
        throwsA(isA<UpdateException>()));
    expect(await directory.list().toList(), isEmpty);
  });

  test('follows GitHub HTTPS redirects but rejects HTTP downgrades', () async {
    final urls = <Uri>[];
    final service = updater(MockClient.streaming((request, _) async {
      urls.add(request.url);
      if (urls.length == 1) {
        return http.StreamedResponse(const Stream.empty(), 302, headers: {
          'location': 'https://release-assets.githubusercontent.com/update.apk'
        });
      }
      return http.StreamedResponse(Stream.value(bytes), 200, contentLength: 16);
    }));
    await service.download(release, onProgress: (_) {});
    expect(urls.last.host, 'release-assets.githubusercontent.com');
    var requests = 0;
    final insecure = updater(MockClient.streaming((_, __) async {
      requests++;
      return http.StreamedResponse(const Stream.empty(), 302,
          headers: {'location': 'http://example.com/update.apk'});
    }));
    await expectLater(insecure.download(release, onProgress: (_) {}),
        throwsA(isA<UpdateException>()));
    expect(requests, 1);
  });

  test('HTTP errors preserve a previous completed file and allow retry',
      () async {
    final previous = File('${directory.path}/update.apk');
    await previous.writeAsBytes(bytes);
    final service = updater(MockClient.streaming(
        (_, __) async => http.StreamedResponse(const Stream.empty(), 503)));
    await expectLater(service.download(release, onProgress: (_) {}),
        throwsA(isA<UpdateException>()));
    expect(await previous.readAsBytes(), bytes);
    expect(await File('${directory.path}/update.apk.part').exists(), isFalse);
  });

  test('cancelling cleans partial data and does not launch the installer',
      () async {
    final body = StreamController<List<int>>();
    final halfway = Completer<void>();
    final service = updater(MockClient.streaming((_, __) async =>
        http.StreamedResponse(body.stream, 200, contentLength: 16)));
    final download = service.download(release, onProgress: (percent) {
      if (percent == 50) halfway.complete();
    });
    final failure = expectLater(download, throwsA(isA<UpdateException>()));
    body.add(bytes.sublist(0, 8));
    await halfway.future;
    service.cancelDownload();
    body.add(bytes.sublist(8));
    await body.close();
    await failure;
    expect(await directory.list().toList(), isEmpty);
    expect(nativeCalls.where((call) => call.method == 'installApk'), isEmpty);
  });

  test('maps native permission errors without exposing URLs or paths',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
          code: 'permission_denied', message: '/private/server/address');
    });
    final service = updater(MockClient((_) async => http.Response('', 500)));
    await expectLater(
        service.install('/private/update.apk'),
        throwsA(
          isA<UpdateException>()
              .having((error) => error.code, 'code', 'permission_denied')
              .having((error) => error.toString(), 'message',
                  isNot(contains('/private/'))),
        ));
  });
}
