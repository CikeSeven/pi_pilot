import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/settings_provider.dart';
import 'ui/main_shell.dart';

void main() {
  runApp(const ProviderScope(child: PiPilotApp()));
}

class PiPilotApp extends ConsumerWidget {
  const PiPilotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    const seed = Color(0xFF6750A4);
    return MaterialApp(
      title: 'PiPilot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: themeMode,
      home: const MainShell(),
    );
  }
}
