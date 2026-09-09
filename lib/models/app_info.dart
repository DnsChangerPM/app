import 'dart:typed_data';

enum AppFilterMode {
  all,
  single,
  allowed,
  disallowed;

  String get labelFa {
    switch (this) {
      case AppFilterMode.all:
        return 'همهٔ برنامه‌ها';
      case AppFilterMode.single:
        return 'تک‌برنامه (بازی/برنامهٔ هدف)';
      case AppFilterMode.allowed:
        return 'فقط برنامه‌های انتخاب‌شده (Whitelist)';
      case AppFilterMode.disallowed:
        return 'همه به جز برنامه‌های انتخاب‌شده (Bypass)';
    }
  }

  String get labelEn {
    switch (this) {
      case AppFilterMode.all:
        return 'All Applications';
      case AppFilterMode.single:
        return 'Single App Focus';
      case AppFilterMode.allowed:
        return 'Only Selected Apps';
      case AppFilterMode.disallowed:
        return 'Bypass Selected Apps';
    }
  }
}

class AppInfo {
  final String packageName;
  final String appName;
  final bool isSystemApp;
  final Uint8List? iconBytes;

  const AppInfo({
    required this.packageName,
    required this.appName,
    this.isSystemApp = false,
    this.iconBytes,
  });

  factory AppInfo.fromMap(Map<dynamic, dynamic> map) {
    return AppInfo(
      packageName: (map['packageName'] as String?) ?? '',
      appName: (map['appName'] as String?) ?? (map['packageName'] as String?) ?? '',
      isSystemApp: map['isSystemApp'] == true,
      iconBytes: map['iconBytes'] as Uint8List?,
    );
  }

  Map<String, dynamic> toMap() => {
        'packageName': packageName,
        'appName': appName,
        'isSystemApp': isSystemApp,
      };
}
