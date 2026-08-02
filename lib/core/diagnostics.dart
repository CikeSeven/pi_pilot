import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 诊断页的数据封装。
///
/// 为什么单独一个文件而不是塞进 NotificationService:诊断页要调六个
/// method(ownerStatus/connectionMetrics/clearConnectionMetrics/
/// watcherDiagnostics/clearWatcherDiagnostics/setFeatureFlag),全部只有
/// Dart→原生方向。MethodChannel 同名实例只用于调用是安全的 ——
/// 原生→Dart 的 handler 仍只有 NotificationService 那一处,不冲突。
class DiagnosticsService {
  DiagnosticsService._();

  static final DiagnosticsService instance = DiagnosticsService._();

  static const MethodChannel _channel = MethodChannel(
    'com.pipilot.pi_pilot/system',
  );

  /// 读 owner 状态快照。失败返回 null,诊断页显示「读取失败」而不是崩。
  Future<OwnerStatusReport?> readOwnerStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'ownerStatus',
      );
      if (raw == null) return null;
      return OwnerStatusReport.fromMap(raw);
    } catch (error) {
      debugPrint('[Diagnostics] ownerStatus 读取失败: $error');
      return null;
    }
  }

  /// 读连接指标(扁平 Map:`count:<reason>` / `last:<reason>` / `detail:...`)。
  Future<Map<String, Object?>> readConnectionMetrics() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'connectionMetrics',
      );
      if (raw == null) return const {};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (error) {
      debugPrint('[Diagnostics] connectionMetrics 读取失败: $error');
      return const {};
    }
  }

  Future<void> clearConnectionMetrics() async {
    try {
      await _channel.invokeMethod<void>('clearConnectionMetrics');
    } catch (error) {
      debugPrint('[Diagnostics] 清空指标失败: $error');
    }
  }

  /// 读 watcher 诊断日志(环形缓冲全文,行尾带线程名)。
  Future<String> readWatcherDiagnostics() async {
    try {
      final raw = await _channel.invokeMethod<String>('watcherDiagnostics');
      return raw ?? '';
    } catch (error) {
      debugPrint('[Diagnostics] watcherDiagnostics 读取失败: $error');
      return '';
    }
  }

  Future<void> clearWatcherDiagnostics() async {
    try {
      await _channel.invokeMethod<void>('clearWatcherDiagnostics');
    } catch (error) {
      debugPrint('[Diagnostics] 清空诊断日志失败: $error');
    }
  }

  /// 切换原生 LAN owner flag。原生侧会立即停掉两个 owner,
  /// 新路径在下一次 startWatcher(进入后台)时生效。
  Future<bool> setNativeLanOwner(bool enabled) async {
    try {
      final raw = await _channel.invokeMethod<bool>('setFeatureFlag', {
        'flag': 'native_lan_owner_v1',
        'enabled': enabled,
      });
      return raw ?? false;
    } catch (error) {
      debugPrint('[Diagnostics] 切换 native_lan_owner_v1 失败: $error');
      return false;
    }
  }
}

/// ownerStatus 的 Dart 模型。两个 owner 的原始 Map 保留,
/// 页面按当前 activeOwner 选取展示;导出时全量带上,
/// 便于排查「flag 切换后旧 owner 是否真的停了」。
@immutable
class OwnerStatusReport {
  const OwnerStatusReport({
    required this.activeOwner,
    required this.nativeLanOwnerFlag,
    required this.ready,
    required this.watcher,
    required this.coordinator,
    required this.keepAlive,
  });

  /// "coordinator" 或 "watcher"。
  final String activeOwner;
  final bool nativeLanOwnerFlag;
  final bool ready;
  final Map<String, Object?> watcher;
  final Map<String, Object?> coordinator;
  final Map<String, Object?> keepAlive;

  static OwnerStatusReport fromMap(Map<Object?, Object?> map) {
    Map<String, Object?> sub(String key) {
      final raw = map[key];
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v));
      }
      return const {};
    }

    return OwnerStatusReport(
      activeOwner: map['activeOwner'] as String? ?? 'watcher',
      nativeLanOwnerFlag: map['nativeLanOwnerFlag'] as bool? ?? false,
      ready: map['ready'] as bool? ?? false,
      watcher: sub('watcher'),
      coordinator: sub('coordinator'),
      keepAlive: sub('keepAlive'),
    );
  }

  /// 当前生效 owner 的状态 Map。
  Map<String, Object?> get active =>
      activeOwner == 'coordinator' ? coordinator : watcher;

  String get activeOwnerLabel =>
      activeOwner == 'coordinator' ? '原生 LAN owner' : '兼容 watcher';

  /// FGS 模式:REALTIME / QUOTA_EXHAUSTED。
  String get backgroundMode => keepAlive['backgroundMode'] as String? ?? '';

  int get quotaExhaustedAt => (keepAlive['quotaExhaustedAt'] as num?)?.toInt() ?? 0;

  Map<String, Object?> toJson() => {
        'activeOwner': activeOwner,
        'nativeLanOwnerFlag': nativeLanOwnerFlag,
        'ready': ready,
        'watcher': watcher,
        'coordinator': coordinator,
        'keepAlive': keepAlive,
      };
}

/// 组装导出用的脱敏 JSON。
///
/// 脱敏在原生侧已完成(token 不进快照、身份截 8 位),这里只做拼装。
/// 诊断日志文本可能含 host:port —— 那是用户自己的局域网地址,
/// 排查「子网错了」必须保留,不属于凭据。
String buildDiagnosticsExport({
  required OwnerStatusReport? owner,
  required Map<String, Object?> metrics,
  required String watcherLog,
  required Map<String, Object?> permission,
}) {
  final payload = <String, Object?>{
    'exportedAt': DateTime.now().toIso8601String(),
    'permission': permission,
    'ownerStatus': owner?.toJson(),
    'metrics': metrics,
    // 只带尾部:全文可能上千行,粘贴到 issue 里不可用。
    'watcherLogTail': watcherLog.split('\n').length > 200
        ? watcherLog.split('\n').sublist(watcherLog.split('\n').length - 200).join('\n')
        : watcherLog,
  };
  return const JsonEncoder.withIndent('  ').convert(payload);
}
