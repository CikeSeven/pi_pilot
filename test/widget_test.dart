import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('PiState.initial is disconnected and empty', () {
    final state = PiState.initial();
    expect(state.status, PiConnStatus.disconnected);
    expect(state.items, isEmpty);
    expect(state.hasSession, isFalse);
    expect(state.isStreaming, isFalse);
  });

  test('copyWith preserves and overrides fields', () {
    final state = PiState.initial().copyWith(
      hasSession: true,
      modelName: 'Kimi K3',
      thinkingLevel: 'high',
      sessionName: 'PiPilot',
    );
    expect(state.hasSession, isTrue);
    expect(state.modelName, 'Kimi K3');
    expect(state.thinkingLevel, 'high');
    expect(state.sessionName, 'PiPilot');
    expect(state.revision, 0);
  });

  test('SettingsRepository round-trips connection + theme + model', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository();
    await repo.saveConnection(host: '10.0.0.2', port: 9377, token: 'abc');
    await repo.saveThemeMode('dark');
    await repo.savePreferredSourceId('desktop:test');
    await repo.saveModelPreference(
      provider: 'kimi-coding',
      modelId: 'k3',
      thinkingLevel: 'high',
    );

    final data = await repo.load();
    expect(data.host, '10.0.0.2');
    expect(data.port, 9377);
    expect(data.token, 'abc');
    expect(data.themeMode, 'dark');
    expect(data.preferredSourceId, 'desktop:test');
    expect(data.modelId, 'k3');
    expect(data.thinkingLevel, 'high');
  });

  test('Hub source and cursor parse protocol v2 data', () {
    final source = SourceInfo.fromMap({
      'id': 'desktop:test',
      'kind': 'desktop',
      'label': 'Desktop',
      'connected': true,
      'epoch': 'epoch-1',
      'capabilities': ['prompt', 'abort'],
      'owner': {'owned': true, 'expiresAt': 1234},
      'ownedByYou': true,
    });
    expect(source.isDesktop, isTrue);
    expect(source.supports('prompt'), isTrue);
    expect(source.ownedByYou, isTrue);

    final cursor = HubCursor.fromMap({
      'hubId': 'hub-1',
      'sourceId': source.id,
      'sourceEpoch': source.epoch,
      'seq': 42,
    });
    expect(cursor.toMap()['seq'], 42);
    expect(cursor.sourceId, 'desktop:test');

    final replacement = SourceInfo(
      id: source.id,
      kind: source.kind,
      label: source.label,
      connected: true,
      epoch: 'epoch-2',
      capabilities: source.capabilities,
      ownerPresent: false,
      ownedByYou: false,
    );
    expect(sourceEpochChanged(source, replacement), isTrue);
    expect(sourceEpochChanged(replacement, replacement), isFalse);
  });

  test('SettingsRepository defaults when empty', () async {
    SharedPreferences.setMockInitialValues({});
    final data = await SettingsRepository().load();
    expect(data.host, '');
    expect(data.port, 9377);
    expect(data.themeMode, 'light');
    expect(data.modelId, isNull);
  });
}
