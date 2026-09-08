import 'dart:async';
import 'dart:convert';

import 'package:dns_changer/services/version_service.dart';
import 'package:dns_changer/widgets/app_update_guard.dart';
import 'package:dns_changer/widgets/update_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'release_info_test.dart' show releaseJson;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'startup waits for the initial update check before showing the app',
      (tester) async {
    final response = Completer<http.Response>();
    final versions = VersionService(
      versionLoader: () async => '1.0.1',
      client: MockClient((_) => response.future),
    );
    await tester.pumpWidget(MaterialApp(
        home: AppUpdateGuard(
      versionService: versions,
      home: const Scaffold(body: Text('Main app')),
    )));
    await tester.pump();
    expect(find.text('Main app'), findsNothing);
    response.complete(http.Response('{}', 503));
    await tester.pumpAndSettle();
    expect(find.text('Main app'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    versions.dispose();
  });

  testWidgets(
      'a resume check replaces every route and Back cannot reveal settings',
      (tester) async {
    var latest = '1.0.1';
    final versions = VersionService(
      versionLoader: () async => '1.0.1',
      client: MockClient((request) async => request.url.host == 'api.github.com'
          ? http.Response(jsonEncode(releaseJson(latest)), 200)
          : http.Response('{}', 503)),
    );
    await versions.initialize();
    await tester.pumpWidget(MaterialApp(
        home: AppUpdateGuard(
      versionService: versions,
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        const Scaffold(body: Text('Settings route')),
                  )),
                  child: const Text('Open settings'),
                ),
              )),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings route'), findsOneWidget);
    latest = '1.0.2';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateGate), findsOneWidget);
    expect(find.text('Settings route'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(UpdateGate), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    versions.dispose();
  });

  testWidgets('normal nested routes still respond to the system Back button',
      (tester) async {
    final versions = VersionService(
      versionLoader: () async => '1.0.1',
      client: MockClient((_) async => http.Response('{}', 503)),
    );
    await versions.initialize();
    await tester.pumpWidget(MaterialApp(
        home: AppUpdateGuard(
      versionService: versions,
      home: Builder(
          builder: (context) => Scaffold(
                  body: TextButton(
                child: const Text('Home'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const Scaffold(body: Text('Nested settings')),
                )),
              ))),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Nested settings'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    versions.dispose();
  });
}
