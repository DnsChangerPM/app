import 'dart:async';

import 'package:dns_changer/models/release_info.dart';
import 'package:dns_changer/services/apk_update_service.dart';
import 'package:dns_changer/widgets/update_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeUpdater extends ApkUpdateService {
  final downloadResult = Completer<String>();
  Completer<void> installResult = Completer<void>();
  void Function(int)? progress;
  int downloads = 0;
  int installs = 0;
  int exits = 0;
  bool cancelled = false;
  bool failExit = false;

  @override
  Future<String> download(ReleaseInfo release,
      {required void Function(int) onProgress}) {
    downloads++;
    progress = onProgress;
    onProgress(0);
    return downloadResult.future;
  }

  @override
  Future<void> install(String path, {String? sha256}) {
    installs++;
    return installResult.future;
  }

  @override
  void cancelDownload() => cancelled = true;

  @override
  Future<void> exitApp() async {
    if (failExit) throw const UpdateException('exit_failed');
    exits++;
  }
}

void main() {
  const release = ReleaseInfo(
    tag: 'v1.0.2',
    name: 'Update',
    apkUrl: 'https://github.com/update.apk',
    apkSize: 16,
  );

  Widget gate(FakeUpdater updater, {ReleaseInfo? available = release}) =>
      MaterialApp(
        home: UpdateGate(
          currentVersion: '1.0.1',
          release: available,
          onRetry: () async => available,
          updateService: updater,
        ),
      );

  testWidgets('has download and exit, and cannot be bypassed with Back',
      (tester) async {
    final updater = FakeUpdater();
    await tester.pumpWidget(gate(updater));
    expect(find.text('دانلود برنامه'), findsOneWidget);
    expect(find.text('خروج از برنامه'), findsOneWidget);
    expect(tester.getTopLeft(find.text('خروج از برنامه')).dy,
        greaterThan(tester.getTopLeft(find.text('دانلود برنامه')).dy));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(UpdateGate), findsOneWidget);
    expect(find.text('Check again'), findsNothing);
  });

  testWidgets('shows actual progress then automatically invokes installation',
      (tester) async {
    final updater = FakeUpdater();
    await tester.pumpWidget(gate(updater));
    await tester.tap(find.text('دانلود برنامه'));
    await tester.pump();
    expect(find.text('0%'), findsOneWidget);
    updater.progress!(47);
    await tester.pump();
    expect(find.text('47%'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.47);
    updater.downloadResult.complete('/cache/updates/update.apk');
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(updater.installs, 1);
    updater.installResult
        .completeError(const UpdateException('install_cancelled'));
    await tester.pumpAndSettle();
    expect(find.text('نصب برنامه'), findsOneWidget);
    expect(find.byType(UpdateGate), findsOneWidget);
    // Cancelling the system installer allows an install retry, not another download.
    updater.installResult = Completer<void>();
    await tester.ensureVisible(find.text('نصب برنامه'));
    await tester.tap(find.text('نصب برنامه'));
    await tester.pump();
    expect(updater.installs, 2);
    expect(updater.downloads, 1);
    updater.installResult.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'download failure leaves retry and exit available without leaking the URL',
      (tester) async {
    final updater = FakeUpdater();
    await tester.pumpWidget(gate(updater));
    await tester.tap(find.text('دانلود برنامه'));
    await tester.pump();
    updater.downloadResult
        .completeError(Exception('https://private.example/server'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://private.example'), findsNothing);
    expect(find.text('دانلود برنامه'), findsOneWidget);
    await tester.tap(find.text('خروج از برنامه'));
    await tester.pumpAndSettle();
    expect(updater.exits, 1);
    expect(updater.cancelled, isTrue);
  });

  testWidgets('exit remains usable during a download', (tester) async {
    final updater = FakeUpdater();
    await tester.pumpWidget(gate(updater));
    await tester.tap(find.text('دانلود برنامه'));
    await tester.pump();
    await tester.tap(find.text('خروج از برنامه'));
    await tester.pump();
    expect(updater.cancelled, isTrue);
    expect(updater.exits, 1);
    updater.downloadResult.completeError(const UpdateException('cancelled'));
    await tester.pumpAndSettle();
  });

  testWidgets('missing release metadata keeps the gate and offers a retry',
      (tester) async {
    final updater = FakeUpdater();
    await tester.pumpWidget(gate(updater, available: null));
    await tester.tap(find.text('دانلود برنامه'));
    await tester.pumpAndSettle();
    expect(updater.downloads, 0);
    expect(
        find.text(const UpdateException('no_release').message), findsOneWidget);
    expect(find.text('دانلود برنامه'), findsOneWidget);
  });

  testWidgets('does not install an obsolete download after the release changes',
      (tester) async {
    final updater = FakeUpdater();
    final available = ValueNotifier<ReleaseInfo?>(release);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<ReleaseInfo?>(
        valueListenable: available,
        builder: (_, current, __) => UpdateGate(
          currentVersion: '1.0.1',
          release: current,
          onRetry: () async => available.value,
          updateService: updater,
        ),
      ),
    ));
    await tester.tap(find.text('دانلود برنامه'));
    await tester.pump();
    available.value = const ReleaseInfo(
      tag: 'v1.0.3',
      name: 'Newer update',
      apkUrl: 'https://github.com/new.apk',
      apkSize: 32,
    );
    await tester.pump();
    updater.downloadResult.complete('/cache/updates/update.apk');
    await tester.pumpAndSettle();
    expect(updater.installs, 0);
    expect(find.text(const UpdateException('update_changed').message),
        findsOneWidget);
    expect(find.text('دانلود برنامه'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    available.dispose();
  });

  testWidgets('a failed VPN shutdown keeps the exit screen usable',
      (tester) async {
    final updater = FakeUpdater()..failExit = true;
    await tester.pumpWidget(gate(updater));
    await tester.tap(find.text('خروج از برنامه'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateGate), findsOneWidget);
    expect(find.text(const UpdateException('exit_failed').message),
        findsOneWidget);
    updater.failExit = false;
    await tester.ensureVisible(find.text('خروج از برنامه'));
    await tester.tap(find.text('خروج از برنامه'));
    await tester.pumpAndSettle();
    expect(updater.exits, 1);
  });

  testWidgets('fits a small display with large text without overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final updater = FakeUpdater();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.5)),
        child: child!,
      ),
      home: UpdateGate(
          currentVersion: '1.0.1',
          release: release,
          onRetry: () async => release,
          updateService: updater),
    ));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('خروج از برنامه'));
    await tester.tap(find.text('خروج از برنامه'));
    await tester.pumpAndSettle();
    expect(updater.exits, 1);
  });
}
