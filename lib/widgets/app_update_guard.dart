import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/home_screen.dart';
import '../services/version_service.dart';
import '../services/vpn_service.dart';
import 'update_gate.dart';

/// Owns the entire in-app navigator, so a required update also covers settings,
/// dialogs and subscription routes, rather than just replacing the home page.
class AppUpdateGuard extends StatefulWidget {
  const AppUpdateGuard(
      {super.key, this.versionService, this.home = const HomeScreen()});

  final VersionService? versionService;
  final Widget home;

  @override
  State<AppUpdateGuard> createState() => _AppUpdateGuardState();
}

class _AppUpdateGuardState extends State<AppUpdateGuard>
    with WidgetsBindingObserver {
  late final VersionService _versions;
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _stoppedForUpdate = false;

  @override
  void initState() {
    super.initState();
    _versions = widget.versionService ?? VersionService.instance;
    WidgetsBinding.instance.addObserver(this);
    _versions.addListener(_policyChanged);
    _policyChanged();
    unawaited(_versions.initialize());
  }

  void _policyChanged() {
    if (_versions.updateRequired && !_stoppedForUpdate) {
      _stoppedForUpdate = true;
      // Do not leave an already running VPN usable behind a mandatory update.
      unawaited(_stopForUpdate());
    } else if (!_versions.updateRequired) {
      _stoppedForUpdate = false;
    }
  }

  Future<void> _stopForUpdate() async {
    try {
      await VpnServiceController().stop();
    } catch (_) {
      // Retry on the next policy/resume notification instead of allowing an
      // unhandled platform error to interrupt the mandatory update screen.
      _stoppedForUpdate = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
          _versions.initialized ? _versions.refresh() : _versions.initialize());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _versions.removeListener(_policyChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _versions,
      builder: (context, _) {
        // A cached update blocks immediately, even before the network responds.
        if (_versions.updateRequired) {
          return UpdateGate(
            currentVersion: _versions.currentVersion,
            release: _versions.availableUpdate,
            onRetry: () async {
              await _versions.refresh();
              return _versions.availableUpdate;
            },
          );
        }
        if (!_versions.initialized) {
          return PopScope(
            canPop: false,
            child: Scaffold(
              body: SafeArea(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                      const Text('در حال بررسی نسخهٔ برنامه…'),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () => _versions.initialize(),
                        child: const Text('تلاش دوباره'),
                      ),
                      TextButton(
                        onPressed: SystemNavigator.pop,
                        child: const Text('خروج از برنامه'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return NavigatorPopHandler(
          onPop: () => _navigatorKey.currentState!.pop(),
          child: Navigator(
            key: _navigatorKey,
            onGenerateRoute: (_) =>
                MaterialPageRoute(builder: (_) => widget.home),
          ),
        );
      },
    );
  }
}
