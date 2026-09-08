enum VpnPhase {
  disconnected,
  requestingPermission,
  connecting,
  connected,
  pausing,
  paused,
  stopping,
  error,
}

/// Authoritative native state, not an optimistic response to a start command.
/// No upstream addresses, backend URLs or repository identifiers are included.
class VpnStatus {
  const VpnStatus({
    this.phase = VpnPhase.disconnected,
    this.errorCode,
    this.notificationsEnabled = true,
    this.revision = -1,
  });

  final VpnPhase phase;
  final String? errorCode;
  final bool notificationsEnabled;
  final int revision;

  bool get isConnected => phase == VpnPhase.connected;
  bool get isPaused => phase == VpnPhase.paused;
  bool get isBusy => const [
        VpnPhase.requestingPermission,
        VpnPhase.connecting,
        VpnPhase.pausing,
        VpnPhase.stopping,
      ].contains(phase);
  bool get hasSession => isConnected || isPaused || isBusy;

  String get label {
    switch (phase) {
      case VpnPhase.connected:
        return 'متصل';
      case VpnPhase.paused:
        return 'توقف موقت';
      case VpnPhase.requestingPermission:
        return 'در انتظار اجازهٔ اندروید…';
      case VpnPhase.connecting:
        return 'در حال اتصال…';
      case VpnPhase.pausing:
        return 'در حال توقف موقت…';
      case VpnPhase.stopping:
        return 'در حال قطع اتصال…';
      case VpnPhase.error:
        return 'اتصال ناموفق';
      case VpnPhase.disconnected:
        return 'متصل نیست';
    }
  }

  String? get errorMessage =>
      errorCode == null ? null : vpnErrorMessage(errorCode!);

  factory VpnStatus.fromMap(Map<dynamic, dynamic> data) {
    final name = data['state'];
    final phase = VpnPhase.values.where((value) => value.name == name);
    return VpnStatus(
      phase: phase.isEmpty ? VpnPhase.error : phase.first,
      errorCode: phase.isEmpty ? 'unavailable' : data['errorCode'] as String?,
      notificationsEnabled: data['notificationsEnabled'] != false,
      revision: (data['revision'] as num?)?.toInt() ?? 0,
    );
  }
}

String vpnErrorMessage(String code) {
  switch (code) {
    case 'permission_denied':
      return 'اجازهٔ VPN داده نشد. برای اتصال، درخواست اندروید را تأیید کنید.';
    case 'permission_required':
      return 'اجازهٔ VPN لازم است؛ از داخل برنامه دوباره اتصال یا ازسرگیری را بزنید.';
    case 'permission_revoked':
      return 'اتصال توسط اندروید قطع شد؛ ممکن است اجازهٔ VPN لغو یا VPN دیگری فعال شده باشد.';
    case 'target_app_missing':
      return 'برنامهٔ هدف پیدا نشد. در تنظیمات نام پکیج را بررسی کنید یا «اعمال DNS فقط روی یک برنامه» را خاموش کنید.';
    case 'invalid_target':
      return 'برنامهٔ هدف نمی‌تواند خود DNS Changer باشد. تنظیمات برنامهٔ هدف را تغییر دهید.';
    case 'invalid_dns':
      return 'آدرس DNS معتبر نیست. یک سرور دیگر انتخاب کنید یا DNS شخصی را ویرایش کنید.';
    case 'foreground_failed':
    case 'start_failed':
      return 'اندروید سرویس اتصال را اجرا نکرد. برنامه را باز نگه دارید و دوباره تلاش کنید.';
    case 'tunnel_closed':
      return 'تونل VPN بسته شد. برای اتصال دوباره دکمهٔ اتصال را بزنید.';
    case 'no_session':
      return 'اتصال قبلی در دسترس نیست. DNS را انتخاب و دوباره متصل شوید.';
    case 'busy':
      return 'عملیات قبلی هنوز تمام نشده است؛ کمی صبر کنید.';
    case 'command_failed':
      return 'عملیات انجام نشد. وضعیت اتصال را بررسی و دوباره تلاش کنید.';
    case 'unavailable':
      return 'وضعیت سرویس VPN در دسترس نیست. برنامه را دوباره باز کنید.';
    default:
      return 'اتصال VPN برقرار نشد. اجازهٔ VPN، برنامهٔ هدف و تنظیمات DNS را بررسی کنید.';
  }
}
