import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the same command + event-channel contract as MainActivity, without
/// claiming that a successful MethodChannel call means establish() succeeded.
class FakeVpnPlatform {
  static const commands = MethodChannel('com.dnschanger.app/vpn');
  static const events = MethodChannel('com.dnschanger.app/vpn_state');
  final calls = <MethodCall>[];
  bool autoConnect = true;
  bool _listening = false;
  Map<String, dynamic> snapshot = {
    'state': 'disconnected',
    'errorCode': null,
    'revision': 0,
    'notificationsEnabled': true,
  };

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (call) async {
      _listening = call.method == 'listen';
      if (_listening) sendEvent(snapshot);
      return null;
    });
    messenger.setMockMethodCallHandler(commands, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getStatus':
          return Map<String, dynamic>.from(snapshot);
        case 'start':
        case 'resume':
          setState(autoConnect ? 'connected' : 'connecting');
          break;
        case 'pause':
          setState('paused');
          break;
        case 'stop':
          setState('disconnected');
          break;
        case 'openNotificationSettings':
          break;
        default:
          throw MissingPluginException();
      }
      return null;
    });
  }

  void setState(String phase,
      {String? errorCode, bool? notificationsEnabled, bool emit = true}) {
    snapshot = {
      'state': phase,
      'errorCode': errorCode,
      'revision': (snapshot['revision'] as int) + 1,
      'notificationsEnabled':
          notificationsEnabled ?? snapshot['notificationsEnabled'],
    };
    if (emit) sendEvent(snapshot);
  }

  void sendEvent(Map<String, dynamic> value) {
    if (!_listening) return;
    ServicesBinding.instance.channelBuffers.push(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
  }

  void dispose() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, null);
    // Widget disposal cancels a broadcast subscription asynchronously. Let a
    // final cancel finish, even if the test's teardown has already started.
    messenger.setMockMethodCallHandler(events, (_) async => null);
    _listening = false;
  }
}
