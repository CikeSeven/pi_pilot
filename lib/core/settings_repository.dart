import 'dart:convert';
import 'dart:math' show Random;

import 'package:shared_preferences/shared_preferences.dart';

import 'device_models.dart';

/// 读取结果(用 record 避免与 state 层互相 import)。
typedef SettingsData = ({
  String host,
  int port,
  String token,
  String? clientId,
  String themeMode,
  String? modelProvider,
  String? modelId,
  String? thinkingLevel,
  bool autoRetry,
  String? preferredSourceId,
  List<String> recentDirs,
  List<String> quickPrompts,
  bool notificationsEnabled,
  bool notificationVibrationEnabled,
  String accent,
  String? preferredSessionId,
  bool p2pEnabled,
  String p2pRendezvous,
  String p2pDeviceId,
  String p2pSecret,
});

/// SharedPreferences 统一持久化层。所有配置键集中在这里。
class SettingsRepository {
  static const _kHost = 'conn.host';
  static const _kPort = 'conn.port';
  static const _kToken = 'conn.token';
  static const _kThemeMode = 'ui.themeMode';
  static const _kModelProvider = 'pi.modelProvider';
  static const _kModelId = 'pi.modelId';
  static const _kThinkingLevel = 'pi.thinkingLevel';
  static const _kAutoRetry = 'pi.autoRetry';
  static const _kPreferredSourceId = 'hub.preferredSourceId';
  // sourceId 里嵌着桌面 pi 的 PID,重启后必然变化。sessionId 不变,
  // 用它作为偏好源失配时的回退依据。
  static const _kPreferredSessionId = 'hub.preferredSessionId';
  static const _kRecentDirs = 'sessions.recentDirs';
  static const _kQuickPrompts = 'ui.quickPrompts';
  static const _kNotificationsEnabled = 'ui.notificationsEnabled';
  static const _kNotificationVibrationEnabled =
      'ui.notificationVibrationEnabled';
  static const _kAccent = 'ui.accentColor';
  // 远程打洞(WebRTC P2P):信令服地址/设备名/配对密钥。
  // 配对密钥只存在本机与信令服配置里,不进仓库、不上行明文。
  static const _kP2pEnabled = 'p2p.enabled';
  static const _kP2pRendezvous = 'p2p.rendezvous';
  static const _kP2pDeviceId = 'p2p.deviceId';
  static const _kP2pSecret = 'p2p.secret';
  /// 稳定客户端身份:重连后 bridge 据此即时接管租约/去重请求,
  /// 不必等旧租约 TTL 过期。首次启动生成并持久化。
  static const _kClientId = 'conn.clientId';
  /// 上次成功的 ICE 模式缓存前缀(p2p.icemode.{deviceId}):
  /// relay 网络的每次重连可省 7s direct 空等。
  static const _kP2pIceModePrefix = 'p2p.icemode.';

  /// 多设备 roster(JSON 数组,元素见 DeviceProfile.toMap)。
  static const _kDeviceList = 'devices.list';

  /// 当前激活设备 id(聊天页读哪台)。
  static const _kActiveDeviceId = 'devices.activeId';

  // -- 多设备 roster ---------------------------------------------------------

  /// 读取设备列表;首次启动时把旧版单设备配置(conn.* / p2p.*)迁移成
  /// roster[0]。迁移后旧键保留只读(留一版做回滚保险),新写入只走新键。
  Future<List<DeviceProfile>> loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDeviceList);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        return [
          for (final item in list)
            if (item is Map)
              DeviceProfile.fromMap(item.cast<String, dynamic>()),
        ];
      } catch (_) {
        return const [];
      }
    }
    // 迁移:旧单设备心智 → roster。旧键 host 为空说明是新装机,不动。
    final host = prefs.getString(_kHost) ?? '';
    if (host.isEmpty) return const [];
    final migrated = DeviceProfile(
      id: generateDeviceId(),
      name: '默认设备',
      host: host,
      port: prefs.getInt(_kPort) ?? 9377,
      token: prefs.getString(_kToken) ?? '',
      transport: DeviceTransport.auto,
      p2pRendezvous:
          _emptyToNull(prefs.getString(_kP2pRendezvous)) ??
          kDefaultRendezvousAddress,
      p2pDeviceId: _emptyToNull(prefs.getString(_kP2pDeviceId)),
      p2pSecret: _emptyToNull(prefs.getString(_kP2pSecret)),
    );
    // 旧版 P2P 有独立开关,关掉就等价 lan(直连失败不回落)。
    final device = (prefs.getBool(_kP2pEnabled) ?? false)
        ? migrated
        : migrated.copyWith(clearP2p: true);
    await saveDevices([device]);
    return [device];
  }

  Future<void> saveDevices(List<DeviceProfile> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kDeviceList,
      jsonEncode([for (final d in devices) d.toMap()]),
    );
  }

  /// 新增或按 id 覆盖一台设备。
  Future<void> upsertDevice(DeviceProfile device) async {
    final devices = await loadDevices();
    final index = devices.indexWhere((d) => d.id == device.id);
    if (index >= 0) {
      devices[index] = device;
    } else {
      devices.add(device);
    }
    await saveDevices(devices);
  }

  Future<void> removeDevice(String deviceId) async {
    final devices = await loadDevices();
    devices.removeWhere((d) => d.id == deviceId);
    await saveDevices(devices);
    if (await loadActiveDeviceId() == deviceId) {
      await saveActiveDeviceId(devices.isEmpty ? null : devices.first.id);
    }
  }

  /// DHCP 自愈:发现里 hubId 命中但地址变了 → 静默更新 host/port。
  /// 返回更新后的设备;没有命中返回 null。
  Future<DeviceProfile?> refreshDeviceAddress({
    required String hubId,
    required String host,
    required int port,
  }) async {
    if (hubId.isEmpty) return null;
    final devices = await loadDevices();
    final index = devices.indexWhere(
      (d) => d.lastHubId == hubId && (d.host != host || d.port != port),
    );
    if (index < 0) return null;
    final updated = devices[index].copyWith(host: host, port: port);
    devices[index] = updated;
    await saveDevices(devices);
    return updated;
  }

  Future<String?> loadActiveDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kActiveDeviceId);
  }

  Future<void> saveActiveDeviceId(String? deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    if (deviceId == null) {
      await prefs.remove(_kActiveDeviceId);
    } else {
      await prefs.setString(_kActiveDeviceId, deviceId);
    }
  }

  static String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// 读取缓存的成功模式('direct'/'relay');7 天过期,连败 2 次作废。
  Future<String?> loadP2pIceMode(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kP2pIceModePrefix$deviceId');
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = map['savedAt'] as int? ?? 0;
      final failCount = map['failCount'] as int? ?? 0;
      final ageMs = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (ageMs > 7 * 24 * 3600 * 1000 || failCount >= 2) return null;
      final mode = map['mode'];
      return mode is String ? mode : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveP2pIceMode(String deviceId, String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_kP2pIceModePrefix$deviceId',
      jsonEncode(<String, dynamic>{
        'mode': mode,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'failCount': 0,
      }),
    );
  }

  Future<void> markP2pIceModeFailed(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kP2pIceModePrefix$deviceId');
    var failCount = 1;
    String mode = 'unknown';
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        failCount = (map['failCount'] as int? ?? 0) + 1;
        mode = map['mode'] as String? ?? mode;
      } catch (_) {}
    }
    await prefs.setString(
      '$_kP2pIceModePrefix$deviceId',
      jsonEncode(<String, dynamic>{
        'mode': mode,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'failCount': failCount,
      }),
    );
  }

  static String _generateClientId() {
    final random = Random.secure();
    final hex = List<int>
        .generate(8, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'app-$hex';
  }

  Future<SettingsData> load() async {
    final prefs = await SharedPreferences.getInstance();
    var clientId = prefs.getString(_kClientId);
    if (clientId == null || clientId.isEmpty) {
      clientId = _generateClientId();
      await prefs.setString(_kClientId, clientId);
    }
    return (
      host: prefs.getString(_kHost) ?? '',
      clientId: clientId,
      port: prefs.getInt(_kPort) ?? 9377,
      token: prefs.getString(_kToken) ?? '',
      themeMode: prefs.getString(_kThemeMode) ?? 'light',
      modelProvider: prefs.getString(_kModelProvider),
      modelId: prefs.getString(_kModelId),
      thinkingLevel: prefs.getString(_kThinkingLevel),
      autoRetry: prefs.getBool(_kAutoRetry) ?? true,
      preferredSourceId: prefs.getString(_kPreferredSourceId),
      recentDirs: prefs.getStringList(_kRecentDirs) ?? const [],
      quickPrompts: prefs.getStringList(_kQuickPrompts) ?? const [],
      notificationsEnabled: prefs.getBool(_kNotificationsEnabled) ?? true,
      notificationVibrationEnabled:
          prefs.getBool(_kNotificationVibrationEnabled) ?? false,
      accent: prefs.getString(_kAccent) ?? 'terracotta',
      preferredSessionId: prefs.getString(_kPreferredSessionId),
      p2pEnabled: prefs.getBool(_kP2pEnabled) ?? false,
      p2pRendezvous: prefs.getString(_kP2pRendezvous) ?? kDefaultRendezvousAddress,
      p2pDeviceId: prefs.getString(_kP2pDeviceId) ?? '',
      p2pSecret: prefs.getString(_kP2pSecret) ?? '',
    );
  }

  Future<void> saveConnection({
    required String host,
    required int port,
    required String token,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHost, host);
    await prefs.setInt(_kPort, port);
    await prefs.setString(_kToken, token);
  }

  Future<void> saveThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode);
  }

  Future<void> saveModelPreference({
    required String? provider,
    required String? modelId,
    required String? thinkingLevel,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (provider != null) await prefs.setString(_kModelProvider, provider);
    if (modelId != null) await prefs.setString(_kModelId, modelId);
    if (thinkingLevel != null) {
      await prefs.setString(_kThinkingLevel, thinkingLevel);
    }
  }

  Future<void> saveAutoRetry(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoRetry, enabled);
  }

  Future<void> savePreferredSource(String sourceId, String? sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPreferredSourceId, sourceId);
    if (sessionId != null && sessionId.isNotEmpty) {
      await prefs.setString(_kPreferredSessionId, sessionId);
    } else {
      await prefs.remove(_kPreferredSessionId);
    }
  }

  Future<void> saveRecentDirs(List<String> dirs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecentDirs, dirs);
  }

  Future<void> saveQuickPrompts(List<String> prompts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kQuickPrompts, prompts);
  }

  Future<void> saveNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotificationsEnabled, enabled);
  }

  Future<void> saveNotificationVibrationEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotificationVibrationEnabled, enabled);
  }

  Future<void> saveAccent(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccent, name);
  }

  Future<void> saveP2pConfig({
    required bool enabled,
    required String rendezvous,
    required String deviceId,
    required String secret,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kP2pEnabled, enabled);
    await prefs.setString(_kP2pRendezvous, rendezvous);
    await prefs.setString(_kP2pDeviceId, deviceId);
    await prefs.setString(_kP2pSecret, secret);
  }
}
