import 'package:dns_changer/models/release_info.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> releaseJson(String version, {bool apk = true}) => {
      'tag_name': 'v$version',
      'name': 'DNS Changer $version',
      'assets': [
        if (apk)
          {
            'name': 'DNS-Changer-v$version.apk',
            'browser_download_url':
                'https://github.com/DnsChangerPM/app/releases/download/v$version/app.apk',
            'size': 16,
          },
      ],
    };

void main() {
  test('compares numeric versions, v prefixes and build metadata', () {
    expect(ReleaseInfo.compareVersions('v1.9.9', '1.10.0'), lessThan(0));
    expect(ReleaseInfo.compareVersions('1.2.10', 'v1.2.9'), greaterThan(0));
    expect(ReleaseInfo.compareVersions('v1.2.0+10200', '1.2.0'), 0);
    expect(ReleaseInfo.isValidVersion('v1.2.0'), isTrue);
    expect(ReleaseInfo.isValidVersion('v1.2.0-beta'), isFalse);
    expect(ReleaseInfo.isValidVersion('latest'), isFalse);
  });

  test('prefers a universal release APK over architecture splits', () {
    final json = releaseJson('1.2.0');
    final assets = json['assets'] as List;
    assets.insert(0, {
      'name': 'app-arm64-v8a-release.apk',
      'browser_download_url': 'https://github.com/split.apk',
      'size': 8,
    });
    assets.add({
      'name': 'app-universal-release.apk',
      'browser_download_url': 'https://github.com/universal.apk',
      'size': 32,
    });
    final release = ReleaseInfo.fromGithubJson(json);
    expect(release.apkUrl, 'https://github.com/universal.apk');
    expect(release.apkSize, 32);
    expect(release.hasApk, isTrue);
  });

  test('does not offer drafts, pre-releases, missing or insecure APKs', () {
    for (final flag in ['draft', 'prerelease']) {
      expect(
          ReleaseInfo.fromGithubJson({...releaseJson('1.2.0'), flag: true})
              .hasApk,
          isFalse);
    }
    expect(ReleaseInfo.fromGithubJson(releaseJson('1.2.0', apk: false)).hasApk,
        isFalse);
    final json = releaseJson('1.2.0');
    (json['assets'] as List).first['browser_download_url'] =
        'http://example.com/app.apk';
    expect(ReleaseInfo.fromGithubJson(json).hasApk, isFalse);
  });

  test('split-only releases are not forced onto incompatible devices', () {
    final json = releaseJson('1.2.0');
    (json['assets'] as List).first['name'] = 'app-arm64-v8a-release.apk';
    expect(ReleaseInfo.fromGithubJson(json).hasApk, isFalse);
  });

  test('retains APK size and optional GitHub SHA-256 in the offline cache', () {
    final hash = List.filled(64, 'a').join();
    final json = releaseJson('1.2.0');
    (json['assets'] as List).first['digest'] = 'sha256:$hash';
    final parsed = ReleaseInfo.fromGithubJson(json);
    final cached = ReleaseInfo.fromGithubJson(parsed.toJson());
    expect(cached.tag, parsed.tag);
    expect(cached.apkUrl, parsed.apkUrl);
    expect(cached.apkSize, parsed.apkSize);
    expect(cached.sha256, hash);
  });
}
