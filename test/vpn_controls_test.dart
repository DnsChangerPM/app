import 'package:dns_changer/models/vpn_status.dart';
import 'package:dns_changer/screens/home_screen.dart';
import 'package:dns_changer/services/custom_dns_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_vpn_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVpnPlatform native;
  const toggle = Key('vpn_toggle');
  const disconnect = Key('vpn_disconnect');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'DNS Changer',
        packageName: 'com.dnschanger.app',
        version: '1.0.2',
        buildNumber: '10002',
        buildSignature: '');
    native = FakeVpnPlatform()..install();
  });
  tearDown(() => native.dispose());

  String? statusLabel(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('vpn_status_label'))).data;

  testWidgets(
      'start stays connecting until establish succeeds and remains cancellable',
      (tester) async {
    native.autoConnect = false;
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(toggle));
    await tester.pump();
    expect(statusLabel(tester), 'در حال اتصال…');
    expect(find.text('Protected'), findsNothing);
    expect(tester.widget<FloatingActionButton>(find.byKey(toggle)).onPressed,
        isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(disconnect)).onPressed,
        isNotNull);
    native.setState('connected');
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'متصل');
    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause resume and full disconnect are separate native commands',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'توقف موقت');
    expect(find.text('ازسرگیری'), findsOneWidget);
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'متصل');
    await tester.tap(find.byKey(disconnect));
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'متصل نیست');
    expect(find.byKey(disconnect), findsNothing);
    expect(
        native.calls
            .where((call) =>
                ['start', 'pause', 'resume', 'stop'].contains(call.method))
            .map((call) => call.method),
        ['start', 'pause', 'resume', 'stop']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('notification actions synchronize to an already open app',
      (tester) async {
    native.setState('connected', emit: false);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    native.setState('paused');
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'توقف موقت');
    native.setState('connected');
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'متصل');
    native.setState('disconnected');
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'متصل نیست');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('older snapshots cannot overwrite a newer connection state',
      (tester) async {
    native.setState('connected', emit: false);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    native.sendEvent(
        {'state': 'connecting', 'revision': 0, 'notificationsEnabled': true});
    await tester.pump();
    expect(statusLabel(tester), 'متصل');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'notification denial explains why controls are hidden and opens settings',
      (tester) async {
    native.setState('connected', notificationsEnabled: false, emit: false);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('vpn_enable_notifications')));
    await tester.tap(find.byKey(const Key('vpn_enable_notifications')));
    await tester.pumpAndSettle();
    expect(
        native.calls.any((call) => call.method == 'openNotificationSettings'),
        isTrue);
    native.setState('connected', notificationsEnabled: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vpn_enable_notifications')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'returning from the background refreshes state even after a missed event',
      (tester) async {
    native.setState('connected', emit: false);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    native.setState('paused', emit: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'توقف موقت');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('establishment and permission failures never display connected',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    native.setState('error', errorCode: 'target_app_missing');
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'اتصال ناموفق');
    expect(find.text(vpnErrorMessage('target_app_missing')), findsOneWidget);
    native.setState('disconnected', errorCode: 'permission_denied');
    await tester.pumpAndSettle();
    expect(statusLabel(tester), 'متصل نیست');
    expect(find.text(vpnErrorMessage('permission_denied')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'editing a paused profile clears its old native resume configuration',
      (tester) async {
    final service = CustomDnsService();
    final profile = await service.save(name: 'My DNS', primary: '1.1.1.1');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_server', profile.id);
    native.setState('paused', emit: false);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await service.save(id: profile.id, name: profile.name, primary: '9.9.9.9');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(native.calls.any((call) => call.method == 'stop'), isTrue);
    expect(statusLabel(tester), 'متصل نیست');
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    final start = native.calls.singleWhere((call) => call.method == 'start');
    expect(start.arguments['addresses'], ['9.9.9.9']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
