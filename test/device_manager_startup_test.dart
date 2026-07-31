import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/device_manager.dart';
import 'package:pi_pilot/state/pi_session.dart';

class _SingleLoadRepository extends SettingsRepository {
  static const device = DeviceProfile(
    id: 'dev-home',
    name: 'Home',
    host: '',
    port: 9377,
    token: '',
  );

  int loadDevicesCalls = 0;
  final _neverCompletes = Completer<List<DeviceProfile>>();

  @override
  Future<List<DeviceProfile>> loadDevices() {
    loadDevicesCalls++;
    if (loadDevicesCalls > 1) return _neverCompletes.future;
    return Future.value(const [device]);
  }

  @override
  Future<String?> loadActiveDeviceId() => Future.value(device.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'device manager hydrates once and retains roster across rebuilds',
    () async {
      final repository = _SingleLoadRepository();
      final container = ProviderContainer(
        overrides: [
          deviceManagerProvider.overrideWith(
            () => DeviceManagerNotifier(repository: repository),
          ),
        ],
      );
      addTearDown(container.dispose);

      final loaded = Completer<void>();
      final subscription = container.listen(deviceManagerProvider, (_, next) {
        if (next.loaded && !loaded.isCompleted) loaded.complete();
      }, fireImmediately: true);
      addTearDown(subscription.close);

      await loaded.future.timeout(const Duration(seconds: 1));

      // DeviceManager watches this family state to keep the connection alive.
      // Changing it forces build() to run again without re-reading the roster.
      await container
          .read(
            piSessionFamilyProvider(_SingleLoadRepository.device.id).notifier,
          )
          .connect(_SingleLoadRepository.device);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(deviceManagerProvider);
      expect(repository.loadDevicesCalls, 1);
      expect(state.loaded, isTrue);
      expect(state.activeDeviceId, _SingleLoadRepository.device.id);
      expect(state.devices, hasLength(1));
      expect(state.devices.single.id, _SingleLoadRepository.device.id);
    },
  );
}
