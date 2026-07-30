import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings_repository.dart';
import '../ui/theme/accent.dart';

export '../ui/theme/accent.dart' show AppAccent;

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
    this.preferredSessionId,
    this.recentDirs = const [],
    this.quickPrompts = const [],
    this.notificationsEnabled = true,
    this.notificationVibrationEnabled = false,
    this.accent = AppAccent.terracotta,
    this.p2pEnabled = false,
    this.p2pRendezvous = '',
    this.p2pDeviceId = '',
    this.p2pSecret = '',
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

  /// 偏好源所属的会话 id。sourceId 里嵌着桌面 pi 的 PID,重启后必然变化;
  /// sessionId 不变,用作 sourceId 失配时的回退依据。
  final String? preferredSessionId;

  /// 最近使用的工作目录(MRU,上限 8)。
  final List<String> recentDirs;

  /// 用户自定义快捷指令。
  final List<String> quickPrompts;
  final bool notificationsEnabled;

  /// 任务事件通知是否震动。Android 通知渠道配置不可变,通知服务会据此选择
  /// 独立的"无震动"或"震动"渠道。默认关闭。
  final bool notificationVibrationEnabled;

  /// 主题强调色。
  final AppAccent accent;

  /// 远程打洞(WebRTC P2P):出门在外经公网信令服交换握手后直连家里电脑。
  /// 直连永远是首选,打洞是直连失败后的自动回退。
  /// v1 只有前台聊天走 P2P;后台通知的原生 watcher 仍是直连-only。
  final bool p2pEnabled;

  /// 信令服地址。裸域名会自动补 wss://;显式 ws:// 只允许回环测试。
  final String p2pRendezvous;

  /// 家里电脑在信令服上的设备名。
  final String p2pDeviceId;

  /// 配对密钥:与信令服 devices 表一致。挑战-应答校验,明文永不上行。
  final String p2pSecret;

  /// 是否已完成首次从磁盘的加载(用于触发自动连接)。
  final bool loaded;

  bool get hasConnection => host.isNotEmpty && token.isNotEmpty;

  /// 打洞四要素是否齐备(开关 + 三个字段)。
  bool get hasP2p =>
      p2pEnabled &&
      p2pRendezvous.isNotEmpty &&
      p2pDeviceId.isNotEmpty &&
      p2pSecret.isNotEmpty;

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
    String? preferredSessionId,
    List<String>? recentDirs,
    List<String>? quickPrompts,
    bool? notificationsEnabled,
    bool? notificationVibrationEnabled,
    AppAccent? accent,
    bool? p2pEnabled,
    String? p2pRendezvous,
    String? p2pDeviceId,
    String? p2pSecret,
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
      preferredSessionId: preferredSessionId ?? this.preferredSessionId,
      recentDirs: recentDirs ?? this.recentDirs,
      quickPrompts: quickPrompts ?? this.quickPrompts,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notificationVibrationEnabled:
          notificationVibrationEnabled ?? this.notificationVibrationEnabled,
      accent: accent ?? this.accent,
      p2pEnabled: p2pEnabled ?? this.p2pEnabled,
      p2pRendezvous: p2pRendezvous ?? this.p2pRendezvous,
      p2pDeviceId: p2pDeviceId ?? this.p2pDeviceId,
      p2pSecret: p2pSecret ?? this.p2pSecret,
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
      preferredSessionId: data.preferredSessionId,
      recentDirs: data.recentDirs,
      quickPrompts: data.quickPrompts,
      notificationsEnabled: data.notificationsEnabled,
      notificationVibrationEnabled: data.notificationVibrationEnabled,
      accent: AppAccent.fromName(data.accent),
      p2pEnabled: data.p2pEnabled,
      p2pRendezvous: data.p2pRendezvous,
      p2pDeviceId: data.p2pDeviceId,
      p2pSecret: data.p2pSecret,
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

  /// 记住选中的源。同时存 sessionId:sourceId 包含 PID,桌面 pi 重启后就失效,
  /// 回退到 sessionId 才能在重启后仍然自动选中同一个会话。
  Future<void> setPreferredSource(String sourceId, String? sessionId) async {
    state = state.copyWith(
      preferredSourceId: sourceId,
      preferredSessionId: sessionId,
    );
    await _repo.savePreferredSource(sourceId, sessionId);
  }

  /// 记录最近使用目录(去重置顶,上限 8)。
  Future<void> touchRecentDir(String cwd) async {
    final dirs = [cwd, ...state.recentDirs.where((d) => d != cwd)];
    final capped = dirs.take(8).toList();
    state = state.copyWith(recentDirs: capped);
    await _repo.saveRecentDirs(capped);
  }

  Future<void> setQuickPrompts(List<String> prompts) async {
    state = state.copyWith(quickPrompts: prompts);
    await _repo.saveQuickPrompts(prompts);
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    state = state.copyWith(notificationsEnabled: enabled);
    await _repo.saveNotificationsEnabled(enabled);
  }

  Future<void> setNotificationVibrationEnabled(bool enabled) async {
    state = state.copyWith(notificationVibrationEnabled: enabled);
    await _repo.saveNotificationVibrationEnabled(enabled);
  }

  Future<void> setAccent(AppAccent accent) async {
    state = state.copyWith(accent: accent);
    await _repo.saveAccent(accent.name);
  }

  Future<void> setP2pConfig({
    required bool enabled,
    required String rendezvous,
    required String deviceId,
    required String secret,
  }) async {
    state = state.copyWith(
      p2pEnabled: enabled,
      p2pRendezvous: rendezvous,
      p2pDeviceId: deviceId,
      p2pSecret: secret,
    );
    await _repo.saveP2pConfig(
      enabled: enabled,
      rendezvous: rendezvous,
      deviceId: deviceId,
      secret: secret,
    );
  }
}
