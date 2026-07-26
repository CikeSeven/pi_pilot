import 'package:shared_preferences/shared_preferences.dart';

/// 读取结果(用 record 避免与 state 层互相 import)。
typedef SettingsData = ({
  String host,
  int port,
  String token,
  String themeMode,
  String? modelProvider,
  String? modelId,
  String? thinkingLevel,
  bool autoRetry,
  String? preferredSourceId,
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

  Future<SettingsData> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      host: prefs.getString(_kHost) ?? '',
      port: prefs.getInt(_kPort) ?? 9377,
      token: prefs.getString(_kToken) ?? '',
      themeMode: prefs.getString(_kThemeMode) ?? 'light',
      modelProvider: prefs.getString(_kModelProvider),
      modelId: prefs.getString(_kModelId),
      thinkingLevel: prefs.getString(_kThinkingLevel),
      autoRetry: prefs.getBool(_kAutoRetry) ?? true,
      preferredSourceId: prefs.getString(_kPreferredSourceId),
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

  Future<void> savePreferredSourceId(String sourceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPreferredSourceId, sourceId);
  }
}
