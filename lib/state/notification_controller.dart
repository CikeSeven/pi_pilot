import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notification_service.dart';
import 'device_alerts.dart';
import 'device_manager.dart';
import 'pi_session.dart';
import 'settings_provider.dart';

@visibleForTesting
typedef WatcherConnectionTarget = ({
  String deviceId,
  String host,
  int port,
  String token,
  String sourceId,
  bool wasStreaming,
});

/// Resolve the watcher target from the active roster device, not the legacy
/// single-device settings. The latter can point at a different bridge after
/// the multi-device migration.
@visibleForTesting
WatcherConnectionTarget? resolveWatcherConnectionTarget({
  required DeviceManagerState manager,
  required PiState session,
}) {
  final deviceId = manager.activeDeviceId;
  final device = deviceId == null
      ? null
      : manager.devices.where((item) => item.id == deviceId).firstOrNull;
  final sourceId = session.selectedSourceId;
  if (device == null ||
      !device.hasLan ||
      sourceId == null ||
      sourceId.isEmpty) {
    return null;
  }
  // A direct watcher cannot observe a P2P-only connection. Leaving the Dart
  // fallback enabled is preferable to claiming a watcher that cannot connect.
  if (session.activeTransport == PiActiveTransport.p2p) return null;
  return (
    deviceId: device.id,
    host: device.host,
    port: device.port,
    token: device.token,
    sourceId: sourceId,
    wasStreaming: session.isStreaming,
  );
}

@visibleForTesting
String nativeWatcherClientId({
  required String appClientId,
  required String deviceId,
}) {
  final owner = appClientId.trim().isEmpty ? deviceId : appClientId.trim();
  return '$owner:native-watcher:$deviceId';
}

typedef _WatcherIdentity = ({
  String? deviceId,
  String? host,
  int? port,
  String? token,
  String? sourceId,
  PiActiveTransport? activeTransport,
});

final _watcherIdentityProvider = Provider<_WatcherIdentity>((ref) {
  final manager = ref.watch(deviceManagerProvider);
  final activeId = manager.activeDeviceId;
  final device = activeId == null
      ? null
      : manager.devices.where((item) => item.id == activeId).firstOrNull;
  final session = ref.watch(piSessionProvider);
  return (
    deviceId: activeId,
    host: device?.host,
    port: device?.port,
    token: device?.token,
    sourceId: session.selectedSourceId,
    activeTransport: session.activeTransport,
  );
});

/// 任务完成通知的标题:「<会话名> 已完成」。会话名取不到时退成通用标题。
/// 活跃设备(本文件)与非活跃设备扇出(device_alerts.dart)共用。
String taskCompletionTitle(String? sessionName) {
  final name = sessionName?.trim();
  return name != null && name.isNotEmpty ? '$name 已完成' : 'PiPilot 任务完成';
}

/// 连接中断提醒使用固定 id,重复断线会更新同一条通知,重连后也能精确取消。
@visibleForTesting
const connectionLostNotificationId = 2;

/// 保证快速的断线/重连状态变化仍按发生顺序操作系统通知。
@visibleForTesting
class NotificationOperationSequencer {
  Future<void> _tail = Future<void>.value();

  Future<void> enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object _, StackTrace _) {});
    return result;
  }
}

/// 常驻通知要展示的会话计数:已连接(dormant 不算)与正在工作中的会话数。
/// sessions 还没就绪(空列表)时返回 null —— 不推状态,原生保留上一份文案。
/// 断开源上残留的 streaming 标记不算工作中。
@visibleForTesting
({int connected, int working})? keepAliveSessionCounts(
  List<HubSession> sessions,
) {
  if (sessions.isEmpty) return null;
  var connected = 0;
  var working = 0;
  for (final session in sessions) {
    if (!session.connected) continue;
    connected++;
    if (session.streaming) working++;
  }
  return (connected: connected, working: working);
}

/// 监听 pi 状态,在需要时发本地通知并保活后台连接:
/// - **前台服务(FGS)**:连上 bridge 时启动 dataSync 服务,维持进程优先级和
///   常驻通知。必须在应用前台启动(Android 12+ 禁止后台首次启动 FGS)。
/// - **原生 watcher**:Dart isolate 被系统暂停时,在原生线程维护局域网观察连接,
///   对账所选 source 的 streaming 状态,实时刷新工作计数和完成通知。
/// - **Dart 兜底**:Dart 仍有调度时继续处理状态;若只在回前台后补到完成,
///   `_streamingWhenBackgrounded` 会补发通知。扩展等待输入、断线也在后台提醒。
///
/// 通知 id 策略:FGS 常驻通知固定 id=1;连接中断固定 id=2;任务通知 Dart
/// 侧从 100 起、原生 watcher 从 200 起。回前台时用 getActiveNotifications
/// 全扫取消(只留 id=1),进程被杀后残留的孤儿通知也一并清掉 —— 绝不能用
/// cancelAll(会把前台服务通知一起干掉,可能导致服务被系统杀)。
class NotificationController extends ConsumerStatefulWidget {
  const NotificationController({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationController> createState() =>
      _NotificationControllerState();
}

class _NotificationControllerState extends ConsumerState<NotificationController>
    with WidgetsBindingObserver {
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  int _notificationId = 99; // 任务通知 id 从 100 起,避开 FGS 常驻通知 id=1

  /// 进入后台时是否正在 streaming。用于进程被杀后回前台补收到完成时兜底发通知。
  bool _streamingWhenBackgrounded = false;

  /// 原生观察连接是否已接管后台事件。接管期间 Dart 侧不再发完成通知,
  /// 否则回前台补收到事件时会和原生通知重复。
  bool _watcherActive = false;
  final _connectionNotificationOperations = NotificationOperationSequencer();

  /// 断线提醒的防抖定时器。
  ///
  /// 断线**立即**弹通知是错的:实测原生 owner 从断连到重连成功只要约 1 秒
  /// (冻结解冻后 onFailure 迟到 → 重连 → READY 216ms),而这条通知带震动、
  /// 用固定 id=2,于是每次瞬态重连都白打扰用户一次。真机验收里用户明确
  /// 反馈「还有连接失败重连的通知」。
  ///
  /// 改为宽限期内不打扰:超过 _connectionLostGrace 仍未恢复才提醒,
  /// 期间恢复就直接取消,用户完全无感。
  Timer? _connectionLostTimer;

  /// 宽限期。取 20s:大于 Bridge 判半开的 30s 一半、也大于退避首档 1s 与
  /// 冻结解冻后的典型重连耗时,足以滤掉全部瞬态断连;真正断网/关机等
  /// 长时间失联仍会如实提醒。
  static const _connectionLostGrace = Duration(seconds: 20);

  int _watcherRequestGeneration = 0;

  bool get _inBackground => _lifecycle != AppLifecycleState.resumed;
  bool get _enabled => ref.read(settingsProvider).notificationsEnabled;
  bool get _vibrate => ref.read(settingsProvider).notificationVibrationEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 原生接管状态由回调驱动,必须在这里就订阅:startWatcher 提交后
    // ready 可能很快到达,晚订阅会漏掉那一次通知。
    NotificationService.instance.watcherReady.addListener(_onWatcherReadyChanged);
    // 初始化完成后立即同步当前连接态。不能只等待 status 下一次变化:
    // 自动连接可能在通知权限请求期间已经完成,connected 不会再次重放。
    unawaited(_initializeNotifications());
  }

  Future<void> _initializeNotifications() async {
    await NotificationService.instance.init();
    if (!mounted) return;
    if (ref.read(piSessionProvider).status == PiConnStatus.connected) {
      _cancelConnectionLostNotification();
    }
    _syncForeground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 防抖定时器必须随组件销毁一起取消,否则回调会打到已 dispose 的 ref 上。
    _connectionLostTimer?.cancel();
    _connectionLostTimer = null;
    NotificationService.instance.watcherReady.removeListener(
      _onWatcherReadyChanged,
    );
    _watcherRequestGeneration++;
    // A startWatcher MethodChannel call can still be in flight when the
    // widget is disposed. Always issue the matching stop to close that race.
    unawaited(NotificationService.instance.stopWatcher());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasBackground = _inBackground;
    _lifecycle = state;
    if (state != AppLifecycleState.resumed) {
      // 进入后台:记录此刻是否在 streaming,供回前台补收完成时兜底判断
      _streamingWhenBackgrounded = ref.read(piSessionProvider).isStreaming;
      // 把后台的连接与通知交给原生线程(Dart isolate 会被 MIUI 停止调度)
      unawaited(_startWatcher());
    } else {
      // 回前台:先收回原生观察连接,避免与 Dart 连接重复收事件
      unawaited(_stopWatcher());
      // 回前台:逐个取消任务通知(用户已回到 app),但绝不碰 FGS 常驻通知
      _cancelTaskNotifications();
      // 回前台且已连着:确保 FGS 在跑(可能因后台断连被停过)
      _syncForeground();
    }
    // 从后台回到前台时,wasBackground 已无用,但保留语义清晰
    debugPrint(
      '[NotificationController] lifecycle: $state, wasBackground=$wasBackground, '
      'streamingWhenBg=$_streamingWhenBackgrounded',
    );
  }

  /// 交接给原生层。缺少任一连接参数(未连接/未选 source)时不启动,
  /// 此时仍由 Dart 的回前台兜底路径负责通知。
  Future<void> _startWatcher() async {
    final requestGeneration = ++_watcherRequestGeneration;
    if (!_inBackground) return;
    if (!_enabled) {
      if (requestGeneration == _watcherRequestGeneration) {
        _watcherActive = false;
        await NotificationService.instance.stopWatcher();
      }
      return;
    }
    final manager = ref.read(deviceManagerProvider);
    final session = ref.read(piSessionProvider);
    final target = resolveWatcherConnectionTarget(
      manager: manager,
      session: session,
    );
    if (target == null) {
      if (requestGeneration != _watcherRequestGeneration) return;
      _watcherActive = false;
      await NotificationService.instance.stopWatcher();
      return;
    }
    final settings = ref.read(settingsProvider);
    final submitted = await NotificationService.instance.startWatcher(
      host: target.host,
      port: target.port,
      token: target.token,
      sourceId: target.sourceId,
      vibrate: settings.notificationVibrationEnabled,
      sessionName: _selectedSessionName(),
      clientId: nativeWatcherClientId(
        appClientId: settings.clientId,
        deviceId: target.deviceId,
      ),
      wasStreaming: target.wasStreaming,
    );
    if (!mounted || requestGeneration != _watcherRequestGeneration) return;
    if (!_inBackground) {
      // 回前台了。startWatcher 只是「已提交」,无论如何都要收回,
      // 否则会留下第二条连接。
      if (submitted) await NotificationService.instance.stopWatcher();
      return;
    }
    // 关键:不再用 submitted 推断接管成功。
    //
    // startWatcher 返回 true 只代表原生受理了启动请求,此时 socket 可能
    // 还没连上、没鉴权、没追平事件。真正的接管由原生的 watcherReady 回调
    // 宣布,_onWatcherReadyChanged 会在那时把 _watcherActive 置为 true。
    // 在此之前 Dart 必须保留兜底通知所有权,否则就是通知空窗。
  }

  /// 原生接管状态变化。只有它能把 _watcherActive 置为 true。
  void _onWatcherReadyChanged() {
    if (!mounted) return;
    final ready = NotificationService.instance.watcherReady.value;
    // 已回前台时忽略迟到的 ready:此时 Dart 自己在连,不该让出所有权。
    final next = ready && _inBackground;
    if (_watcherActive == next) return;
    setState(() {
      _watcherActive = next;
    });
  }

  Future<void> _stopWatcher() async {
    ++_watcherRequestGeneration;
    _watcherActive = false;
    // Do not gate this on _watcherActive: the native start call may have
    // completed after the lifecycle callback, and still needs cancellation.
    await NotificationService.instance.stopWatcher();
  }

  void _cancelTaskNotifications() {
    unawaited(NotificationService.instance.cancelTaskNotifications());
  }

  /// 首次连上后启动保活。瞬时断线时 [hasSession] 仍为 true,服务必须继续
  /// 运行,否则后台重连计时器也会随进程降级而停摆。只有显式断开才停止。
  void _syncForeground() {
    final session = ref.read(piSessionProvider);
    if (session.hasSession && !_inBackground) {
      unawaited(NotificationService.instance.startForeground());
      // 服务(重)启动后立刻推一份状态,不能只等 listener 的下一次变化。
      _pushKeepAliveStatus();
    } else if (!session.hasSession) {
      unawaited(NotificationService.instance.stopForeground());
    }
  }

  /// 把当前连接与会话计数推给原生常驻通知。FGS 没在跑(hasSession=false)
  /// 或 sessions 还没就绪时不推 —— 原生侧只记录不刷新,保留上一份文案。
  void _pushKeepAliveStatus() {
    final session = ref.read(piSessionProvider);
    if (!session.hasSession) return;
    final counts = keepAliveSessionCounts(session.sessions);
    if (counts == null) return;
    unawaited(
      NotificationService.instance.updateKeepAliveStatus(
        connected: session.status == PiConnStatus.connected,
        sessions: counts.connected,
        working: counts.working,
      ),
    );
  }

  void _notify(String title, [String? body]) {
    if (!_enabled) return;
    if (!_inBackground) return;
    final id = ++_notificationId;
    unawaited(
      NotificationService.instance.show(
        id: id,
        title: title,
        body: body,
        vibrate: _vibrate,
      ),
    );
  }

  void _notifyConnectionLost() {
    if (!_enabled || !_inBackground) return;
    // 防抖:先起定时器,宽限期内恢复就不打扰。重复断线只保留最后一次计时。
    _connectionLostTimer?.cancel();
    _connectionLostTimer = Timer(_connectionLostGrace, () {
      _connectionLostTimer = null;
      // 到点再确认一次:期间可能已恢复,或应用已回前台。
      if (!mounted || !_enabled || !_inBackground) return;
      if (ref.read(piSessionProvider).status == PiConnStatus.connected) return;
      unawaited(
        _connectionNotificationOperations.enqueue(
          () => NotificationService.instance.show(
            id: connectionLostNotificationId,
            title: '与 bridge 的连接已断开',
            body: '将自动重连',
            vibrate: _vibrate,
          ),
        ),
      );
    });
  }

  void _cancelConnectionLostNotification() {
    // 计时中的提醒一并取消,否则重连成功后宽限期到点仍会弹出来。
    _connectionLostTimer?.cancel();
    _connectionLostTimer = null;
    unawaited(
      _connectionNotificationOperations.enqueue(
        () => NotificationService.instance.cancelById(
          connectionLostNotificationId,
        ),
      ),
    );
  }

  /// 当前选中会话的显示名(会话名 > 目录名 > id 前 8 位),供完成通知标题
  /// 和原生 watcher 使用。sessions 里没有这个源时退到 pi 自己的会话名。
  String? _selectedSessionName() {
    final session = ref.read(piSessionProvider);
    return session.sessions
            .where((s) => s.sourceId == session.selectedSourceId)
            .firstOrNull
            ?.displayName ??
        session.sessionName;
  }

  /// 任务完成:isStreaming true -> false。后台实时通知;或前台兜底(完成发生在
  /// 后台期间,进程被杀后回前台才补收到)。
  void _notifyTaskComplete() {
    if (!_enabled) return;
    // Dart 在后台仍收到完成,或回前台补到后台期间的完成。
    final shouldNotify = _inBackground || _streamingWhenBackgrounded;
    // 消费兜底标记,避免后续前台正常完成误触发
    _streamingWhenBackgrounded = false;
    if (!shouldNotify) return;
    // 原生观察连接已接管后台通知,这里再发就是重复
    if (_watcherActive) return;
    final id = ++_notificationId;
    unawaited(
      NotificationService.instance.show(
        id: id,
        title: taskCompletionTitle(_selectedSessionName()),
        body: '点击查看结果',
        vibrate: _vibrate,
      ),
    );
    unawaited(
      NotificationService.instance.logDiagnostic(
        'task complete trigger: id=$id background=$_inBackground',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 非活跃设备的任务完成提醒(多设备扇出)。挂在这里保证它与
    // 通知控制器同生命周期;活跃设备的通知仍由下面的 listener 负责。
    ref.watch(deviceAlertsProvider);

    // 后台切换激活设备、source、实际通道或连接地址时重新交接 watcher，
    // 避免原生连接继续订阅旧 bridge。
    ref.listen(_watcherIdentityProvider, (previous, next) {
      if (previous == null || previous == next) return;
      if (_inBackground) unawaited(_startWatcher());
    });

    // 常驻通知文案:连接状态或会话计数变化时推给原生刷新。
    ref.listen(
      piSessionProvider.select(
        (s) => (s.status, keepAliveSessionCounts(s.sessions)),
      ),
      (prev, next) => _pushKeepAliveStatus(),
    );

    // 任务完成:isStreaming true -> false
    ref.listen(piSessionProvider.select((s) => s.isStreaming), (prev, next) {
      if (prev == true && next == false) {
        _notifyTaskComplete();
      } else if (prev == false && next == true) {
        // 新任务开始:重置兜底标记(新任务不算"后台期间的完成")
        _streamingWhenBackgrounded = false;
      }
    });

    // 后台会话跑完(并发会话:手机看着 A,B 在后台跑完了)
    ref.listen(piSessionProvider.select((s) => s.backgroundFinishTick), (
      prev,
      next,
    ) {
      if (prev == null || next <= prev) return;
      final name = ref.read(piSessionProvider).backgroundFinishName;
      _notify('${name ?? "另一个会话"} 已完成', '点击查看结果');
    });

    // 扩展等待输入
    ref.listen(piSessionProvider.select((s) => s.pendingUiRequest), (
      prev,
      next,
    ) {
      if (prev == null && next != null) {
        _notify('扩展等待你的输入', next.title);
      }
    });

    // 连接状态:连上时确保 FGS 已启动;瞬时断线保留 FGS 给自动重连。
    ref.listen(piSessionProvider.select((s) => s.status), (prev, next) {
      if (next == PiConnStatus.connected) {
        _cancelConnectionLostNotification();
        _syncForeground();
      } else if (prev == PiConnStatus.connected) {
        unawaited(
          NotificationService.instance.logDiagnostic(
            'bridge disconnected: next=${next.name} background=$_inBackground',
          ),
        );
        _syncForeground();
        _notifyConnectionLost();
      }
    });

    // 显式断开会把 hasSession 清零。此监听与连接状态分开,确保即使用户在
    // connecting 阶段断开,也会释放 wake lock 并移除常驻通知。
    ref.listen(piSessionProvider.select((s) => s.hasSession), (prev, next) {
      if (prev == true && !next) _syncForeground();
    });

    return widget.child;
  }
}
