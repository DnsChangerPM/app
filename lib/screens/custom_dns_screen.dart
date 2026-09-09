import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dns_server.dart';
import '../services/custom_dns_service.dart';
import '../services/dns_backup_service.dart';
import '../services/dns_speed_test_service.dart';

class CustomDnsScreen extends StatefulWidget {
  const CustomDnsScreen({super.key});

  @override
  State<CustomDnsScreen> createState() => _CustomDnsScreenState();
}

class _CustomDnsScreenState extends State<CustomDnsScreen> {
  final _service = CustomDnsService();
  final _backupService = DnsBackupService.instance;
  List<DnsServer> _profiles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _service.load();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _loading = false;
    });
  }

  Future<void> _edit([DnsServer? profile]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DnsEditor(service: _service, profile: profile),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _delete(DnsServer profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف DNS شخصی؟'),
          content: Text('«${profile.name}» از فهرست سرورها حذف می‌شود.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.delete(profile.id);
      if (mounted) await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حذف انجام نشد؛ دوباره تلاش کنید.')),
      );
    }
  }

  Future<void> _exportProfiles() async {
    if (_profiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('سرور شخصی برای خروجی گرفتن وجود ندارد.')),
      );
      return;
    }
    await _backupService.copyToClipboard(_profiles);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تنظیمات DNS شخصی در کلیپ‌بورد کپی شد.')),
      );
    }
  }

  Future<void> _importProfiles() async {
    final controller = TextEditingController();
    final imported = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('ورود DNS از فایل / متن JSON'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('متن JSON پشتیبان را در کادر زیر جای‌گذاری کنید:', style: TextStyle(fontSize: 13, color: Colors.white70)),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 5,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  hintText: '{\n  "custom_servers": [...]\n}',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) controller.text = data!.text!;
              },
              child: const Text('جای‌گذاری از کلیپ‌بورد'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final count = await _backupService.importAndSave(controller.text);
                  if (context.mounted) {
                    Navigator.pop(context, true);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('$count سرور DNS با موفقیت اضافه شد.')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.toString())),
                    );
                  }
                }
              },
              child: const Text('ورود و ذخیره'),
            ),
          ],
        ),
      ),
    );

    if (imported == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('DNS شخصی'),
          actions: [
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: 'خروجی گرفتن',
              onPressed: _exportProfiles,
            ),
            IconButton(
              icon: const Icon(Icons.file_download_outlined),
              tooltip: 'ورود از پشتیبان',
              onPressed: _importProfiles,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'DNS دلخواهتان را اضافه کنید، سپس آن را در صفحهٔ اصلی '
                    'انتخاب کنید و دکمهٔ اتصال را بزنید. آدرس‌های IPv4 و IPv6 '
                    'با پورت 53 پشتیبانی می‌شوند.',
                    style: TextStyle(color: Colors.white70, height: 1.7),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('افزودن DNS شخصی'),
                  ),
                  const SizedBox(height: 20),
                  if (_profiles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        'هنوز DNS شخصی ذخیره نکرده‌اید.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  for (final profile in _profiles)
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsetsDirectional.only(
                          start: 16,
                          end: 4,
                          top: 8,
                          bottom: 8,
                        ),
                        title: Text(profile.name),
                        subtitle: Text(
                          profile.addresses.join('\n'),
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.right,
                        ),
                        onTap: () => _edit(profile),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'ویرایش',
                              onPressed: () => _edit(profile),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'حذف',
                              onPressed: () => _delete(profile),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _DnsEditor extends StatefulWidget {
  const _DnsEditor({required this.service, this.profile});

  final CustomDnsService service;
  final DnsServer? profile;

  @override
  State<_DnsEditor> createState() => _DnsEditorState();
}

class _DnsEditorState extends State<_DnsEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _primary;
  late final TextEditingController _secondary;
  bool _saving = false;
  bool _testing = false;
  int? _testPing;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _name = TextEditingController(text: profile?.name ?? '');
    _primary = TextEditingController(text: profile?.addresses.first ?? '');
    _secondary = TextEditingController(
      text: profile != null && profile.addresses.length > 1
          ? profile.addresses[1]
          : '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _primary.dispose();
    _secondary.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final ip = _primary.text.trim();
    if (CustomDnsService.addressError(ip) != null) {
      setState(() => _error = 'ابتدا یک آدرس معتبر برای DNS اصلی وارد کنید');
      return;
    }
    setState(() {
      _testing = true;
      _testPing = null;
      _error = null;
    });

    final ping = await DnsSpeedTestService.instance.pingAddress(ip);
    if (mounted) {
      setState(() {
        _testing = false;
        _testPing = ping;
        if (ping == null) {
          _error = 'پاسخی از این سرور دریافت نشد (Timeout)';
        }
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.save(
        id: widget.profile?.id,
        name: _name.text,
        primary: _primary.text,
        secondary: _secondary.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'ذخیره انجام نشد؛ آدرس‌ها را بررسی و دوباره تلاش کنید.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title:
              Text(widget.profile == null ? 'افزودن DNS شخصی' : 'ویرایش DNS'),
          content: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const Key('dns_name'),
                    controller: _name,
                    enabled: !_saving,
                    maxLength: 60,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'نام DNS'),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'یک نام برای DNS وارد کنید'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _addressField(_primary, optional: false),
                  const SizedBox(height: 16),
                  _addressField(_secondary, optional: true),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _testing || _saving ? null : _testConnection,
                        icon: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.speed, size: 16),
                        label: const Text('تست پینگ سرور'),
                      ),
                      if (_testPing != null)
                        Text(
                          'پینگ: $_testPing ms',
                          style: const TextStyle(
                            color: Color(0xFF00D1B2),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: const TextStyle(color: Colors.redAccent)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'در حال ذخیره…' : 'ذخیره'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressField(TextEditingController controller,
      {required bool optional}) {
    return TextFormField(
      key: Key(optional ? 'dns_secondary' : 'dns_primary'),
      controller: controller,
      enabled: !_saving,
      textDirection: TextDirection.ltr,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: optional ? TextInputAction.done : TextInputAction.next,
      decoration: InputDecoration(
        labelText: optional ? 'DNS دوم (اختیاری)' : 'DNS اصلی',
        hintText: optional ? '2606:4700:4700::1001' : '1.1.1.1',
        errorMaxLines: 3,
      ),
      validator: (value) =>
          CustomDnsService.addressError(value, optional: optional),
      onFieldSubmitted: optional ? (_) => _save() : null,
    );
  }
}
