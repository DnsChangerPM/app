/// Parsed GitHub release info for update checks.
class ReleaseInfo {
  final String tag;
  final String name;
  final String? apkUrl;
  final int apkSize;
  final String? notes;

  const ReleaseInfo({
    required this.tag,
    required this.name,
    this.apkUrl,
    this.apkSize = 0,
    this.notes,
  });

  /// Compare two dotted version strings ("1.2.3" vs "1.2.10").
  static int compareVersions(String a, String b) {
    final pa = _parse(a);
    final pb = _parse(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static List<int> _parse(String v) {
    final cleaned = v
        .replaceAll(RegExp(r'^v'), '')
        .split('+')
        .first
        .split('-')
        .first;
    return cleaned
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
  }

  factory ReleaseInfo.fromGithubJson(Map<String, dynamic> json) {
    final assets = (json['assets'] as List?) ?? [];
    Map<String, dynamic>? apkAsset;
    var apkSize = 0;
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.endsWith('.apk')) {
        apkAsset = a as Map<String, dynamic>;
        apkSize = a['size'] as int? ?? 0;
        // prefer the universal / release apk
        if (name.contains('release') || name.contains('universal')) break;
      }
    }
    return ReleaseInfo(
      tag: (json['tag_name'] as String?) ?? '0',
      name: (json['name'] as String?) ?? (json['tag_name'] as String?) ?? '0',
      apkUrl: apkAsset?['browser_download_url'] as String?,
      apkSize: apkSize,
      notes: json['body'] as String?,
    );
  }
}
