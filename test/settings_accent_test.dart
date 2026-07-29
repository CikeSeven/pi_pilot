import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsRepository accent', () {
    test('默认 terracotta,round-trip 持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      expect((await repo.load()).accent, 'terracotta');
      await repo.saveAccent('blush');
      expect((await repo.load()).accent, 'blush');
    });
  });

  group('SettingsNotifier accent', () {
    test('hydration 读取持久化值', () async {
      SharedPreferences.setMockInitialValues({'ui.accentColor': 'brick'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).loaded, isTrue);
      expect(container.read(settingsProvider).accent, AppAccent.brick);
    });

    test('setAccent 更新状态并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).setAccent(AppAccent.slate);
      expect(container.read(settingsProvider).accent, AppAccent.slate);
      expect((await SettingsRepository().load()).accent, 'slate');
    });

    test('未知持久化值回退 terracotta', () async {
      SharedPreferences.setMockInitialValues({'ui.accentColor': 'gone'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).accent, AppAccent.terracotta);
    });
  });
}
