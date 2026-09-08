/// A stable, installable GitHub release (also used for the offline update cache).
class ReleaseInfo {
  final String tag;
  final String name;
  final String? apkUrl;
  final int apkSize;
  final String? sha256;
  final String? notes;

  const ReleaseInfo({
    required this.tag,
    required this.name,
    this.apkUrl,
    this.apkSize = 0,
    this.sha256,
    this.notes,
  });

  static final _versionPattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$');

  static bool isValidVersion(String version) =>
      _versionPattern.hasMatch(version.trim());

  bool get hasApk {
    final uri = Uri.tryParse(apkUrl ?? '');
    return isValidVersion(tag) &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  /// Compare numeric versions, ignoring the optional v prefix and build number.
  static int compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .trim()
        .replaceFirst(RegExp(r'^v'), '')
        .split('+')
        .first
        .split('-')
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final pa = parse(a);
    final pb = parse(b);
    final length = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < length; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  factory ReleaseInfo.fromGithubJson(Map<String, dynamic> json) {
    Map<String, dynamic>? apkAsset;
    var bestScore = -1;
    // Do not offer unfinished or pre-release builds as mandatory updates.
    if (json['draft'] != true && json['prerelease'] != true) {
      for (final asset in (json['assets'] as List? ?? const [])) {
        if (asset is! Map<String, dynamic>) continue;
        final name = (asset['name'] as String? ?? '').toLowerCase();
        final uri =
            Uri.tryParse(asset['browser_download_url'] as String? ?? '');
        if (!name.endsWith('.apk') ||
            name.contains('debug') ||
            uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        // Prefer a universal APK; a device must not be forced to install an
        // arbitrary architecture-specific asset when a universal one exists.
        final split = RegExp(r'arm64|armeabi|x86').hasMatch(name);
        if (split && !name.contains('universal')) continue;
        final score = name.contains('universal')
            ? 3
            : name.contains('release')
                ? 2
                : 1;
        if (score > bestScore) {
          apkAsset = asset;
          bestScore = score;
        }
      }
    }
    final digest = apkAsset?['digest'] as String?;
    final hash =
        digest != null && RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)
            ? digest.substring(7).toLowerCase()
            : null;
    return ReleaseInfo(
      tag: json['tag_name'] as String? ?? '0.0.0',
      name: json['name'] as String? ?? json['tag_name'] as String? ?? '',
      apkUrl: apkAsset?['browser_download_url'] as String?,
      apkSize: (apkAsset?['size'] as num?)?.toInt() ?? 0,
      sha256: hash,
      notes: json['body'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'tag_name': tag,
        'name': name,
        'body': notes,
        'assets': [
          if (apkUrl != null)
            {
              'name': 'app-universal-release.apk',
              'browser_download_url': apkUrl,
              'size': apkSize,
              if (sha256 != null) 'digest': 'sha256:$sha256',
            },
        ],
      };
}
