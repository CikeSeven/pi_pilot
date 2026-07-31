import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/device_models.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('clientId 首次启动生成并持久化,格式 app-{16hex}', () async {
    final repo = SettingsRepository();
    final first = await repo.load();
    expect(first.clientId, isNotNull);
    expect(first.clientId, matches(RegExp(r'^app-[0-9a-f]{16}$')));
    final second = await repo.load();
    expect(second.clientId, first.clientId, reason: '重载必须读到同一个身份');
  });

  test('首次空 roster 可以添加并读回设备', () async {
    final repo = SettingsRepository();
    const device = DeviceProfile(
      id: 'dev-first',
      name: 'Test desktop',
      host: '192.168.1.10',
      port: 9377,
      token: 'mobile-token',
      transport: DeviceTransport.lan,
      lastHubId: 'hub-first',
    );

    await repo.upsertDevice(device);

    final devices = await repo.loadDevices();
    expect(devices, hasLength(1));
    expect(devices.single.id, device.id);
    expect(devices.single.name, device.name);
    expect(devices.single.host, device.host);
    expect(devices.single.token, device.token);
    expect(devices.single.lastHubId, device.lastHubId);
  });

  test('ICE 模式缓存:写入后可读,失败计数满 2 次作废', () async {
    final repo = SettingsRepository();
    expect(await repo.loadP2pIceMode('dev-1'), isNull);

    await repo.saveP2pIceMode('dev-1', 'relay');
    expect(await repo.loadP2pIceMode('dev-1'), 'relay');

    await repo.markP2pIceModeFailed('dev-1');
    expect(await repo.loadP2pIceMode('dev-1'), 'relay', reason: '失败 1 次仍有效');
    await repo.markP2pIceModeFailed('dev-1');
    expect(await repo.loadP2pIceMode('dev-1'), isNull, reason: '连败 2 次作废');

    // 成功会重置失败计数
    await repo.saveP2pIceMode('dev-1', 'direct');
    expect(await repo.loadP2pIceMode('dev-1'), 'direct');
  });

  test('ICE 模式缓存按 deviceId 隔离', () async {
    final repo = SettingsRepository();
    await repo.saveP2pIceMode('dev-1', 'relay');
    expect(await repo.loadP2pIceMode('dev-2'), isNull);
  });
}
