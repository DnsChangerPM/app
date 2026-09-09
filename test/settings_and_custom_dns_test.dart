import 'package:dns_changer/screens/custom_dns_screen.dart';
import 'package:dns_changer/screens/home_screen.dart';
import 'package:dns_changer/screens/settings_screen.dart';
import 'package:dns_changer/services/app_config.dart';
import 'package:dns_changer/services/custom_dns_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_speed_tester.dart';
import 'support/fake_vpn_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeVpnPlatform native;
  const urlChannel = MethodChannel('plugins.flutter.io/url_launcher');
  late List<MethodCall> vpnCalls;
  late List<MethodCall> urlCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'DNS Changer',
      packageName: 'com.dnschanger.app',
      version: '1.0.2',
      buildNumber: '10002',
      buildSignature: '',
    );
    native = FakeVpnPlatform()..install();
    vpnCalls = native.calls;
    urlCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(urlChannel, (call) async {
      urlCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    native.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(urlChannel, null);
  });

  test('old user-editable backend URL is removed, not restored on upgrade',
      () async {
    SharedPreferences.setMockInitialValues(
        {'config_api_base_url': 'https://old.example'});
    await AppConfig.load();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('config_api_base_url'), isFalse);
    expect(AppConfig.apiBaseUrl, isNot('https://old.example'));
  });

  testWidgets('settings hide the backend and show all three Telegram contacts',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Cloudflare API'), findsNothing);
    expect(find.text('Worker URL'), findsNothing);
    expect(find.text(AppConfig.apiBaseUrl), findsNothing);
    expect(find.byType(TextField), findsOneWidget); // Only the target package.
    expect(find.text('DNS شخصی'), findsOneWidget);
    for (final entry in {
      '@DnsChangerPM': AppConfig.telegramChannel,
      '@DnsChangerPMGP': AppConfig.telegramGroup,
      '@AnishtayiN': AppConfig.telegramCreator,
    }.entries) {
      expect(find.text(entry.key), findsOneWidget);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(urlCalls.last.arguments['url'], entry.value);
    }
  });

  testWidgets('custom DNS editor validates, saves, edits and deletes profiles',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomDnsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزودن DNS شخصی'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dns_name')), 'My DNS');
    await tester.enterText(find.byKey(const Key('dns_primary')), 'not.an.ip');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dns_primary')), findsOneWidget);
    expect(await CustomDnsService().load(), isEmpty);
    await tester.enterText(find.byKey(const Key('dns_primary')), '8.8.8.8');
    await tester.enterText(find.byKey(const Key('dns_secondary')), '8.8.4.4');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(find.text('My DNS'), findsOneWidget);
    expect((await CustomDnsService().load()).single.addresses,
        ['8.8.8.8', '8.8.4.4']);
    await tester.tap(find.byTooltip('ویرایش'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dns_primary')), '9.9.9.9');
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect((await CustomDnsService().load()).single.addresses.first, '9.9.9.9');
    await tester.tap(find.byTooltip('حذف'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'حذف'));
    await tester.pumpAndSettle();
    expect(await CustomDnsService().load(), isEmpty);
  });

  testWidgets(
      'a custom profile is selectable and sends its addresses to the VPN',
      (tester) async {
    final profile = await CustomDnsService().save(
      name: 'Home DNS',
      primary: '192.168.1.1',
      secondary: '2606:4700:4700::1111',
    );
    await tester.pumpWidget(
        MaterialApp(home: HomeScreen(speedTest: FakeSpeedTestService())));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Home DNS'));
    await tester.tap(find.text('Home DNS'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_server'), profile.id);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final start = vpnCalls.singleWhere((call) => call.method == 'start');
    expect(start.arguments['addresses'], profile.addresses);
  });

  testWidgets(
      'new profiles appear on home immediately after returning from settings',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: HomeScreen(speedTest: FakeSpeedTestService())));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DNS شخصی'));
    await tester.pumpAndSettle();
    // Simulate a persisted form submission while this management route is open.
    await CustomDnsService().save(name: 'New personal DNS', primary: '1.0.0.1');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('New personal DNS'), findsOneWidget);
  });
}
