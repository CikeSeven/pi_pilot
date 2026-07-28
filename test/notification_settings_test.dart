import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notification vibration setting', () {
    test('defaults to off and persists changes', () async {
      SharedPreferences.setMockInitialValues({});
      final repository = SettingsRepository();

      expect((await repository.load()).notificationVibrationEnabled, isFalse);
      await repository.saveNotificationVibrationEnabled(true);
      expect((await repository.load()).notificationVibrationEnabled, isTrue);
    });

    test('notifier hydrates and saves vibration preference', () async {
      SharedPreferences.setMockInitialValues({
        'ui.notificationVibrationEnabled': true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(settingsProvider).notificationVibrationEnabled,
        isTrue,
      );

      await container
          .read(settingsProvider.notifier)
          .setNotificationVibrationEnabled(false);
      expect(
        container.read(settingsProvider).notificationVibrationEnabled,
        isFalse,
      );
      expect(
        (await SettingsRepository().load()).notificationVibrationEnabled,
        isFalse,
      );
    });
  });
}
