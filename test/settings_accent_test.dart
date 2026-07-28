import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsRepository accent', () {
    test('默认 blue,round-trip 持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      expect((await repo.load()).accent, 'blue');
      await repo.saveAccent('pink');
      expect((await repo.load()).accent, 'pink');
    });
  });

  group('SettingsNotifier accent', () {
    test('hydration 读取持久化值', () async {
      SharedPreferences.setMockInitialValues({'ui.accentColor': 'orange'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).loaded, isTrue);
      expect(container.read(settingsProvider).accent, AppAccent.orange);
    });

    test('setAccent 更新状态并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      await container.read(settingsProvider.notifier).setAccent(AppAccent.teal);
      expect(container.read(settingsProvider).accent, AppAccent.teal);
      expect((await SettingsRepository().load()).accent, 'teal');
    });

    test('未知持久化值回退 blue', () async {
      SharedPreferences.setMockInitialValues({'ui.accentColor': 'gone'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).accent, AppAccent.blue);
    });
  });
}
