import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/release_info.dart';
import '../services/version_service.dart';

/// Shown when the running version is marked as "killed" (a newer release was
/// published and this one is disabled). Downloads the APK directly - the user
/// is never sent to GitHub.
class UpdateGate extends StatelessWidget {
  final ReleaseInfo? release;
  final VoidCallback onRetry;

  const UpdateGate({super.key, required this.release, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final vs = VersionService.instance;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.system_update_alt, size: 96, color: Color(0xFF3AA6FF)),
              const SizedBox(height: 24),
              const Text(
                'A new update is required',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'This version (${vs.currentVersion}) has been disabled.\n'
                'Please download the latest version to continue.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
              if (release != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Latest: ${release!.name}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF00D1B2), fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: 32),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3AA6FF),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: () => _download(context),
                icon: const Icon(Icons.download),
                label: const Text('Download update'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: onRetry,
                child: const Text('Check again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context) async {
    final url = release?.apkUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No download link yet, please try again.')),
      );
      return;
    }
    // Direct download: opens the browser download (or a download manager)
    // without navigating to the GitHub page.
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the download link.')),
      );
    }
  }
}
