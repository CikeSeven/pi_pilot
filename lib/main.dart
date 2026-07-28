import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/app_lifecycle.dart';
import 'state/notification_controller.dart';
import 'state/settings_provider.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: PiPilotApp()));
}

class PiPilotApp extends ConsumerWidget {
  const PiPilotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (themeMode, accent) = ref.watch(
      settingsProvider.select((s) => (s.themeMode, s.accent)),
    );
    return MaterialApp(
      title: 'PiPilot',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(accent),
      darkTheme: buildDarkTheme(accent),
      themeMode: themeMode,
      home: const AppLifecycleHandler(
        child: NotificationController(child: AppShell()),
      ),
    );
  }
}
