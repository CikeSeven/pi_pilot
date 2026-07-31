import 'package:flutter_test/flutter_test.dart';
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
