import 'package:flutter/services.dart';

/// Dart wrapper around the native VpnService (Kotlin).
class VpnServiceController {
  static const MethodChannel _channel = MethodChannel('com.dnschanger.app/vpn');

  /// Start the VPN with the given upstream DNS addresses.
  /// Returns `true` if it started immediately, `false` if a permission dialog
  /// was shown (the VPN will start automatically once granted).
  Future<bool> start(List<String> addresses, {int port = 53, List<String> allowedPackages = const []}) async {
    try {
      final res = await _channel.invokeMethod<bool>('start', {
        'addresses': addresses,
        'port': port,
        'allowedPackages': allowedPackages,
      });
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // ignore
    }
  }

  Future<bool> isRunning() async {
    try {
      final res = await _channel.invokeMethod<bool>('isRunning');
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }
}
