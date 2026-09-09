/// Policy for the "apply DNS on a single app" target package.
///
/// Free (unlicensed) installs are locked to [defaultTargetPackage]. Only an
/// active license unlocks editing, and the enforcement is applied everywhere
/// the value is read — not just in the settings UI — so an older saved value
/// (or a manually edited preference) can never leak into a free session.
class TargetPackagePolicy {
  static const String defaultTargetPackage = 'com.tencent.ig';
  static const String prefsKey = 'target_package';

  static final RegExp _packagePattern =
      RegExp(r'^[a-zA-Z]\w*(\.[a-zA-Z]\w*)+$');

  static bool isValidPackage(String value) =>
      _packagePattern.hasMatch(value.trim());

  /// The package that must actually be used, given the license state.
  static String resolve(String? saved, {required bool licenseActive}) {
    if (!licenseActive) return defaultTargetPackage;
    final value = (saved ?? '').trim();
    if (value.isEmpty || !isValidPackage(value)) return defaultTargetPackage;
    return value;
  }
}
