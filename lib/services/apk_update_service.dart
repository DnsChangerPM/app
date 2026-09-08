import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/release_info.dart';

class UpdateException implements Exception {
  const UpdateException(this.code);
  final String code;

  String get message {
    switch (code) {
      case 'exit_failed':
        return 'خروج انجام نشد. اتصال را از اعلان برنامه قطع کنید و دوباره خروج را بزنید.';
      case 'cancelled':
        return 'دانلود متوقف شد.';
      case 'permission_denied':
        return 'برای به‌روزرسانی، اجازهٔ «نصب از این منبع» را فعال کنید و دوباره نصب را بزنید.';
      case 'install_cancelled':
        return 'نصب کامل نشد. برای ادامه، دوباره «نصب برنامه» را بزنید.';
      case 'signature_mismatch':
        return 'امضای نسخهٔ جدید با برنامهٔ نصب‌شده یکسان نیست. با سازنده تماس بگیرید.';
      case 'not_newer':
        return 'کد نسخهٔ فایل جدید بالاتر از نسخهٔ نصب‌شده نیست. با سازنده تماس بگیرید.';
      case 'invalid_apk':
      case 'checksum_mismatch':
        return 'فایل دانلودشده معتبر نیست. دوباره دانلود کنید.';
      case 'storage_error':
        return 'ذخیرهٔ فایل انجام نشد. فضای خالی دستگاه را بررسی کنید.';
      case 'missing_apk':
        return 'فایل نصب پیدا نشد. دوباره دانلود کنید.';
      case 'install_unavailable':
        return 'نصب‌کنندهٔ اندروید باز نشد. تنظیمات نصب برنامه را بررسی کنید.';
      case 'update_changed':
        return 'نسخهٔ جدیدتری منتشر شده است. دوباره دانلود را بزنید.';
      case 'no_release':
        return 'فایل نسخهٔ جدید هنوز در دسترس نیست. اینترنت را بررسی و دوباره تلاش کنید.';
      default:
        return 'دانلود انجام نشد. اتصال اینترنت و فضای خالی را بررسی و دوباره تلاش کنید.';
    }
  }

  @override
  String toString() =>
      message; // Never expose a backend URL or a local file path.
}

/// Streams an APK to private app cache, then asks Android's package installer to
/// update this app. No browser downloads, external storage or silent installs.
class ApkUpdateService {
  ApkUpdateService({
    http.Client Function()? clientFactory,
    MethodChannel? channel,
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _channel = channel ?? const MethodChannel('com.dnschanger.app/updater');

  final http.Client Function() _clientFactory;
  final MethodChannel _channel;
  http.Client? _activeClient;
  bool _cancelled = false;
  bool _disposed = false;

  Future<String> download(
    ReleaseInfo release, {
    required void Function(int percent) onProgress,
  }) async {
    if (_disposed || _activeClient != null) {
      throw const UpdateException('cancelled');
    }
    if (!release.hasApk) throw const UpdateException('no_release');
    final client = _clientFactory();
    _activeClient = client;
    _cancelled = false;
    File? partial;
    RandomAccessFile? output;
    try {
      onProgress(0);
      final directory =
          await _channel.invokeMethod<String>('getUpdateDirectory');
      _checkCancelled();
      if (directory == null || directory.isEmpty) {
        throw const UpdateException('storage_error');
      }
      partial = File('$directory/update.apk.part');
      final destination = File('$directory/update.apk');
      final response = await _request(client, Uri.parse(release.apkUrl!));
      _checkCancelled();
      if (response.statusCode != 200) {
        throw const UpdateException('download_failed');
      }
      final contentLength = response.contentLength ?? 0;
      final total = release.apkSize > 0 ? release.apkSize : contentLength;
      if (total <= 0 ||
          (contentLength > 0 &&
              release.apkSize > 0 &&
              contentLength != total)) {
        throw const UpdateException('invalid_apk');
      }
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      var lastPercent = 0;
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        _checkCancelled();
        received += chunk.length;
        if (received > total) throw const UpdateException('invalid_apk');
        await output.writeFrom(chunk);
        // 100% means the complete file is flushed and ready for the installer.
        final percent = (received * 100 ~/ total).clamp(0, 99).toInt();
        if (percent != lastPercent) {
          lastPercent = percent;
          onProgress(percent);
        }
      }
      if (received != total || received < 4) {
        throw const UpdateException('invalid_apk');
      }
      await output.flush();
      await output.close();
      output = null;
      _checkCancelled();
      final header =
          await partial.openRead(0, 4).expand((bytes) => bytes).toList();
      if (header[0] != 0x50 ||
          header[1] != 0x4b ||
          header[2] != 3 ||
          header[3] != 4) {
        throw const UpdateException('invalid_apk');
      }
      if (await destination.exists()) await destination.delete();
      _checkCancelled();
      await partial.rename(destination.path);
      onProgress(100);
      return destination.path;
    } on UpdateException {
      rethrow;
    } on FileSystemException {
      throw const UpdateException('storage_error');
    } catch (_) {
      if (_cancelled || _disposed) throw const UpdateException('cancelled');
      throw const UpdateException('download_failed');
    } finally {
      try {
        await output?.close();
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {}
      client.close();
      _activeClient = null;
    }
  }

  Future<http.StreamedResponse> _request(http.Client client, Uri uri) async {
    // GitHub redirects to its asset CDN. Follow redirects ourselves so a
    // downgrade to unencrypted HTTP can never feed the package installer.
    for (var redirects = 0; redirects <= 5; redirects++) {
      _checkCancelled();
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const UpdateException('download_failed');
      }
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/octet-stream'
        ..headers['Accept-Encoding'] = 'identity';
      final response =
          await client.send(request).timeout(const Duration(seconds: 20));
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      await response.stream.listen((_) {}).cancel();
      if (location == null) throw const UpdateException('download_failed');
      uri = uri.resolve(location);
    }
    throw const UpdateException('download_failed');
  }

  Future<void> install(String path, {String? sha256}) async {
    try {
      await _channel.invokeMethod<void>('installApk', {
        'path': path,
        if (sha256 != null) 'sha256': sha256,
      });
    } on PlatformException catch (error) {
      throw UpdateException(error.code);
    } catch (_) {
      throw const UpdateException('install_unavailable');
    }
  }

  Future<void> exitApp() async {
    try {
      await _channel.invokeMethod<void>('exitApp');
    } on MissingPluginException {
      await SystemNavigator.pop();
    } on PlatformException {
      throw const UpdateException('exit_failed');
    }
  }

  void _checkCancelled() {
    if (_cancelled || _disposed) throw const UpdateException('cancelled');
  }

  void cancelDownload() {
    _cancelled = true;
    _activeClient?.close();
  }

  void dispose() {
    _disposed = true;
    cancelDownload();
  }
}
