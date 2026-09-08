import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/app_config.dart';
import 'widgets/app_update_guard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const DnsChangerApp());
}

class DnsChangerApp extends StatelessWidget {
  const DnsChangerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DNS Changer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1220),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3AA6FF),
          secondary: Color(0xFF00D1B2),
          surface: Color(0xFF111B2E),
          onSurface: Colors.white,
          error: Color(0xFFFF5C5C),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1220),
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const AppUpdateGuard(),
    );
  }
}
