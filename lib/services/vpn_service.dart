import 'package:flutter/services.dart';

import '../models/vpn_status.dart';

class VpnException implements Exception {
  const VpnException(this.code);
  final String code;
  String get message => vpnErrorMessage(code);
  @override
  String toString() => message;
}

/// Native commands only acknowledge receipt; [states] / [getStatus] report when
/// Android actually established, paused, revoked or closed its VPN interface.
class VpnServiceController {
  static const MethodChannel _channel = MethodChannel('com.dnschanger.app/vpn');
  static const EventChannel _events =
      EventChannel('com.dnschanger.app/vpn_state');
  static final Stream<VpnStatus> _states = _events.receiveBroadcastStream().map(
        (event) => VpnStatus.fromMap(event as Map<dynamic, dynamic>),
      );

  Stream<VpnStatus> get states => _states;

  Future<void> start(
    List<String> addresses, {
    int port = 53,
    List<String> allowedPackages = const [],
    List<String> disallowedPackages = const [],
    bool enableIpv6 = true,
    int timeoutMs = 2500,
  }) {
    return _command('start', {
      'addresses': addresses,
      'port': port,
      'allowedPackages': allowedPackages,
      'disallowedPackages': disallowedPackages,
      'enableIpv6': enableIpv6,
      'timeoutMs': timeoutMs,
    });
  }

  Future<void> pause() => _command('pause');
  Future<void> resume() => _command('resume');

  Future<void> stop() async {
    try {
      await _command('stop');
    } on VpnException catch (error) {
      // The Android-only update guard can also be built by Flutter widget tests.
      if (error.code != 'unavailable') rethrow;
    }
  }

  Future<VpnStatus> getStatus() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (data == null) throw const VpnException('unavailable');
      return VpnStatus.fromMap(data);
    } on PlatformException catch (error) {
      throw VpnException(error.code);
    } on MissingPluginException {
      throw const VpnException('unavailable');
    }
  }

  Future<bool> isRunning() async => (await getStatus()).isConnected;
  Future<void> openNotificationSettings() =>
      _command('openNotificationSettings');

  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    try {
      final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>('getInstalledApps');
      if (list != null) {
        return list.map((item) => Map<String, dynamic>.from(item)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<Map<String, dynamic>?> getNetworkInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getNetworkInfo');
      return info;
    } catch (_) {}
    return null;
  }

  Future<void> _command(String method,
      [Map<String, dynamic>? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      // Platform error messages can include native paths/addresses. Use codes.
      throw VpnException(error.code);
    } on MissingPluginException {
      throw const VpnException('unavailable');
    }
  }
}
