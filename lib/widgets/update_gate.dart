import 'package:flutter/material.dart';

import '../models/release_info.dart';
import '../services/apk_update_service.dart';

/// Non-dismissible mandatory update screen. Android still requires the user's
/// confirmation; declining installation never unlocks the outdated app.
class UpdateGate extends StatefulWidget {
  const UpdateGate({
    super.key,
    required this.currentVersion,
    required this.release,
    required this.onRetry,
    this.updateService,
  });

  final String currentVersion;
  final ReleaseInfo? release;
  final Future<ReleaseInfo?> Function() onRetry;
  final ApkUpdateService? updateService;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  late final ApkUpdateService _updater;
  int _progress = 0;
  bool _checking = false;
  bool _downloading = false;
  bool _installing = false;
  bool _exiting = false;
  String? _apkPath;
  ReleaseInfo? _targetRelease;
  bool _releaseInvalidated = false;
  String? _error;

  bool get _busy => _checking || _downloading || _installing || _exiting;

  @override
  void initState() {
    super.initState();
    _updater = widget.updateService ?? ApkUpdateService();
  }

  bool _sameRelease(ReleaseInfo? a, ReleaseInfo? b) =>
      a?.tag == b?.tag && a?.apkUrl == b?.apkUrl && a?.sha256 == b?.sha256;

  @override
  void didUpdateWidget(covariant UpdateGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = !_sameRelease(oldWidget.release, widget.release);
    if ((_downloading || _installing) &&
        changed &&
        _targetRelease != null &&
        !_sameRelease(_targetRelease, widget.release)) {
      _releaseInvalidated = true;
    }
    if (!_busy && changed) {
      _apkPath = null;
      _targetRelease = null;
      _progress = 0;
      _error = null;
    }
  }

  Future<void> _download() async {
    if (_busy) return;
    if (_apkPath != null) {
      await _install();
      return;
    }
    final refreshMetadata = widget.release == null || _error != null;
    setState(() {
      _checking = true;
      _error = null;
      _progress = 0;
      _releaseInvalidated = false;
    });
    try {
      final release = refreshMetadata ? await widget.onRetry() : widget.release;
      if (!mounted || _exiting) return;
      if (release == null) throw const UpdateException('no_release');
      setState(() {
        _checking = false;
        _downloading = true;
        _targetRelease = release;
      });
      final path = await _updater.download(release, onProgress: (percent) {
        if (mounted && !_exiting) setState(() => _progress = percent);
      });
      if (!mounted || _exiting) return;
      if (_releaseInvalidated) {
        throw const UpdateException('update_changed');
      }
      setState(() {
        _apkPath = path;
        _targetRelease = release;
        _downloading = false;
        _progress = 100;
      });
      // Open the OS installer as soon as the complete APK is available.
      await _install();
    } catch (error) {
      if (mounted && !_exiting) {
        setState(() => _error = error is UpdateException
            ? error.message
            : const UpdateException('download_failed').message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _install() async {
    if (_apkPath == null || _installing) return;
    if (_releaseInvalidated) {
      setState(() {
        _apkPath = null;
        _targetRelease = null;
        _progress = 0;
        _error = const UpdateException('update_changed').message;
      });
      return;
    }
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await _updater.install(_apkPath!, sha256: _targetRelease?.sha256);
    } catch (error) {
      if (!mounted || _exiting) return;
      setState(() {
        final failure = error is UpdateException
            ? error
            : const UpdateException('install_unavailable');
        _error = failure.message;
        if ([
          'invalid_apk',
          'checksum_mismatch',
          'missing_apk',
          'signature_mismatch',
          'not_newer'
        ].contains(failure.code)) {
          _apkPath = null;
          _targetRelease = null;
          _progress = 0;
        }
      });
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    setState(() {
      _exiting = true;
      _error = null;
    });
    _updater.cancelDownload();
    try {
      await _updater.exitApp();
    } catch (_) {
      if (mounted)
        setState(() => _error = const UpdateException('exit_failed').message);
    } finally {
      if (mounted) setState(() => _exiting = false);
    }
  }

  @override
  void dispose() {
    _updater.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight - 48),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.system_update_alt,
                          size: 88, color: Color(0xFF3AA6FF)),
                      const SizedBox(height: 24),
                      const Text(
                        'به‌روزرسانی برنامه ضروری است',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'برای ادامهٔ استفاده از برنامه، نسخهٔ جدید را نصب کنید.\n'
                        'نسخهٔ فعلی: ${widget.currentVersion}',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: Colors.white70, height: 1.7),
                      ),
                      if (widget.release != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'نسخهٔ جدید: ${widget.release!.tag}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFF00D1B2)),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (_downloading || _apkPath != null || _installing) ...[
                        Text(
                          '$_progress%',
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 30, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _progress / 100,
                          minHeight: 8,
                          semanticsLabel: 'درصد دانلود برنامه',
                          semanticsValue: '$_progress%',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _progress < 100
                              ? 'در حال دانلود برنامه…'
                              : 'دانلود کامل شد. نصب را در پنجرهٔ اندروید تأیید کنید. '
                                  'اگر اجازهٔ نصب خواسته شد، «نصب از این منبع» را فعال کنید.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white70, height: 1.7),
                        ),
                        const SizedBox(height: 24),
                      ],
                      if (_error != null) ...[
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.redAccent, height: 1.7),
                        ),
                        const SizedBox(height: 16),
                      ],
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: _busy ? null : _download,
                        icon: _busy && !_exiting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(_apkPath == null
                                ? Icons.download
                                : Icons.install_mobile),
                        label: Text(_checking
                            ? 'در حال بررسی…'
                            : _downloading
                                ? 'در حال دانلود…'
                                : _installing
                                    ? 'در انتظار تأیید نصب…'
                                    : _apkPath != null
                                        ? 'نصب برنامه'
                                        : 'دانلود برنامه'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _exiting ? null : _exit,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: const Icon(Icons.exit_to_app),
                        label: const Text('خروج از برنامه'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
