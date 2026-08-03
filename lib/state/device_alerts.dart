import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_models.dart';
import '../core/notification_service.dart';
import 'device_manager.dart';
import 'notification_controller.dart';
import 'pi_session.dart';
import 'settings_provider.dart';

/// 非活跃设备的任务完成提醒。
///
/// 活跃设备的所有通知仍归 NotificationController(区分前后台、原生
/// watcher 接管、FGS 保活);这里只补「别的设备」的完成事件——你正在
/// 看 A 设备的会话时,B 设备上的 agent 跑完了,手机也该响一声。
///
/// 不在 v1 范围(后续迭代):非活跃设备的断线提醒、多设备 FGS 常驻文案。
final deviceAlertsProvider = NotifierProvider<DeviceAlertsNotifier, void>(
  DeviceAlertsNotifier.new,
);

class DeviceAlertsNotifier extends Notifier<void> {
  /// 任务通知 id 分段:活跃设备 Dart 侧从 100 起、原生 watcher 从 200 起,
  /// 扇出从 300 起,互不覆盖;回前台全扫取消对三段一视同仁。
  int _notificationId = 299;

  /// 每台设备上一份 (taskCompletionTick, backgroundFinishTick) 基线。
  /// build() 是「watch 到变化就重跑」的模型,完成只认显式 tick。
  final Map<String, int> _completionTick = {};
  final Map<String, int> _finishTick = {};

  @override
  void build() {
    final manager = ref.watch(deviceManagerProvider);
    final rosterIds = {for (final d in manager.devices) d.id};
    // 设备从 roster 删除后清掉基线,避免无界累积。
    _completionTick.removeWhere((id, _) => !rosterIds.contains(id));
    _finishTick.removeWhere((id, _) => !rosterIds.contains(id));

    for (final device in manager.devices) {
      if (device.id == manager.activeDeviceId) {
        // 活跃设备交给 NotificationController。清掉基线:它变成非活跃时
        // 重新记基线,不把活跃期间的变化补发成通知。
        _completionTick.remove(device.id);
        _finishTick.remove(device.id);
        continue;
      }
      final snapshot = ref.watch(
        piSessionFamilyProvider(
          device.id,
        ).select((s) => (s.taskCompletionTick, s.backgroundFinishTick)),
      );
      final lastCompletion = _completionTick[device.id];
      final lastTick = _finishTick[device.id];
      _completionTick[device.id] = snapshot.$1;
      _finishTick[device.id] = snapshot.$2;
      // 首次见到这台设备:只记基线,不把接入前的状态补发成通知。
      if (lastCompletion == null || lastTick == null) continue;
      if (snapshot.$1 > lastCompletion) {
        _notifyTaskComplete(device);
      } else if (snapshot.$2 > lastTick) {
        _notifyBackgroundFinish(device);
      }
    }
  }

  bool get _enabled => ref.read(settingsProvider).notificationsEnabled;

  bool get _vibrate => ref.read(settingsProvider).notificationVibrationEnabled;

  /// 选中会话跑完(isStreaming true→false),标题复用活跃设备的格式。
  void _notifyTaskComplete(DeviceProfile device) {
    if (!_enabled) return;
    final s = ref.read(piSessionFamilyProvider(device.id));
    final name =
        s.sessions
            .where((item) => item.sourceId == s.selectedSourceId)
            .firstOrNull
            ?.displayName ??
        s.sessionName;
    unawaited(
      NotificationService.instance.show(
        id: ++_notificationId,
        title: taskCompletionTitle(name),
        // 多台设备同时跑时,设备名是区分「谁完成了」的关键信息。
        body: '${device.name} · 点击查看结果',
        vibrate: _vibrate,
      ),
    );
  }

  /// 非选中会话跑完(backgroundFinishTick 递增)。
  void _notifyBackgroundFinish(DeviceProfile device) {
    if (!_enabled) return;
    final s = ref.read(piSessionFamilyProvider(device.id));
    unawaited(
      NotificationService.instance.show(
        id: ++_notificationId,
        title: '${s.backgroundFinishName ?? "另一个会话"} 已完成',
        body: device.name,
        vibrate: _vibrate,
      ),
    );
  }
}
