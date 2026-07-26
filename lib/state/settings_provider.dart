import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings_repository.dart';

/// 全局设置:连接、外观、模型偏好。所有改动立即持久化。
class AppSettings {
  const AppSettings({
    this.host = '',
    this.port = 9377,
    this.token = '',
    this.themeMode = ThemeMode.light,
    this.modelProvider,
    this.modelId,
    this.thinkingLevel,
    this.autoRetry = true,
    this.preferredSourceId,
    this.loaded = false,
  });

  final String host;
  final int port;
  final String token;
  final ThemeMode themeMode;
  final String? modelProvider;
  final String? modelId;
  final String? thinkingLevel;
  final bool autoRetry;
  final String? preferredSourceId;

  /// 是否已完成首次从磁盘的加载(用于触发自动连接)。
  final bool loaded;

  bool get hasConnection => host.isNotEmpty && token.isNotEmpty;

  AppSettings copyWith({
    String? host,
    int? port,
    String? token,
    ThemeMode? themeMode,
    String? modelProvider,
    String? modelId,
    String? thinkingLevel,
    bool? autoRetry,
    String? preferredSourceId,
    bool? loaded,
  }) {
    return AppSettings(
      host: host ?? this.host,
      port: port ?? this.port,
      token: token ?? this.token,
      themeMode: themeMode ?? this.themeMode,
      modelProvider: modelProvider ?? this.modelProvider,
      modelId: modelId ?? this.modelId,
      thinkingLevel: thinkingLevel ?? this.thinkingLevel,
      autoRetry: autoRetry ?? this.autoRetry,
      preferredSourceId: preferredSourceId ?? this.preferredSourceId,
      loaded: loaded ?? this.loaded,
    );
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  final SettingsRepository _repo = SettingsRepository();

  @override
  AppSettings build() {
    _hydrate();
    return const AppSettings();
  }

  Future<void> _hydrate() async {
    final data = await _repo.load();
    state = AppSettings(
      host: data.host,
      port: data.port,
      token: data.token,
      themeMode: switch (data.themeMode) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      },
      modelProvider: data.modelProvider,
      modelId: data.modelId,
      thinkingLevel: data.thinkingLevel,
      autoRetry: data.autoRetry,
      preferredSourceId: data.preferredSourceId,
      loaded: true,
    );
  }

  Future<void> setConnection({
    required String host,
    required int port,
    required String token,
  }) async {
    state = state.copyWith(host: host, port: port, token: token);
    await _repo.saveConnection(host: host, port: port, token: token);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _repo.saveThemeMode(mode.name);
  }

  Future<void> setModelPreference({
    String? provider,
    String? modelId,
    String? thinkingLevel,
  }) async {
    state = state.copyWith(
      modelProvider: provider,
      modelId: modelId,
      thinkingLevel: thinkingLevel,
    );
    await _repo.saveModelPreference(
      provider: provider,
      modelId: modelId,
      thinkingLevel: thinkingLevel,
    );
  }

  Future<void> setAutoRetry(bool enabled) async {
    state = state.copyWith(autoRetry: enabled);
    await _repo.saveAutoRetry(enabled);
  }

  Future<void> setPreferredSourceId(String sourceId) async {
    state = state.copyWith(preferredSourceId: sourceId);
    await _repo.savePreferredSourceId(sourceId);
  }
}
