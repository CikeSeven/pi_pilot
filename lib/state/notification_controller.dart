import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notification_service.dart';
import 'pi_session.dart';
import 'settings_provider.dart';

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
/// - **前台服务(FGS)保活**:连上 bridge 时启动 dataSync 前台服务,把进程提到前台
///   优先级。这样后台时 Dart isolate 仍能响应 bridge 的 10s 协议 ping,连接不至于
///   被 20s 超时掐断 -> 实时收到 agent_end -> isStreaming 翻转 -> 触发完成通知。
///   必须在应用前台时启动(Android 12+ 后台启动会抛 ForegroundServiceStartNotAllowedException)。
/// - **任务完成通知**:isStreaming true->false。后台实时收到就实时通知;
///   若进程曾被杀、回前台才补收到完成(_streamingWhenBackgrounded 兜底),也补发通知。
/// - 扩展等待输入、连接中断:后台时通知。
///
/// 通知 id 策略:FGS 常驻通知固定 id=1;任务通知 Dart 侧从 100 起、原生
/// watcher 从 200 起。回前台时用 getActiveNotifications 全扫取消(只留 id=1),
/// 进程被杀后残留的孤儿通知也一并清掉 —— 绝不能用 cancelAll(会把前台
/// 服务通知一起干掉,可能导致服务被系统杀)。
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

  bool get _inBackground => _lifecycle != AppLifecycleState.resumed;
  bool get _enabled => ref.read(settingsProvider).notificationsEnabled;
  bool get _vibrate => ref.read(settingsProvider).notificationVibrationEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 初始化完成后立即同步当前连接态。不能只等待 status 下一次变化:
    // 自动连接可能在通知权限请求期间已经完成,connected 不会再次重放。
    unawaited(_initializeNotifications());
  }

  Future<void> _initializeNotifications() async {
    await NotificationService.instance.init();
    if (!mounted) return;
    _syncForeground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (!_enabled) return;
    final settings = ref.read(settingsProvider);
    final sourceId = ref.read(piSessionProvider).selectedSourceId;
    if (settings.host.isEmpty || sourceId == null || sourceId.isEmpty) return;
    final started = await NotificationService.instance.startWatcher(
      host: settings.host,
      port: settings.port,
      token: settings.token,
      sourceId: sourceId,
      vibrate: settings.notificationVibrationEnabled,
    );
    if (mounted) _watcherActive = started;
  }

  Future<void> _stopWatcher() async {
    if (!_watcherActive) return;
    _watcherActive = false;
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

  /// 任务完成:isStreaming true -> false。后台实时通知;或前台兜底(完成发生在
  /// 后台期间,进程被杀后回前台才补收到)。
  void _notifyTaskComplete() {
    if (!_enabled) return;
    // 后台实时收到完成(FGS 保活成功) 或 前台兜底(回前台补收到后台期间的完成)
    final shouldNotify = _inBackground || _streamingWhenBackgrounded;
    // 消费兜底标记,避免后续前台正常完成误触发
    _streamingWhenBackgrounded = false;
    if (!shouldNotify) return;
    // 原生观察连接已接管后台通知,这里再发就是重复
    if (_watcherActive) return;
    final items = ref.read(piSessionProvider).items;
    final lastAssistant = items.reversed.whereType<AssistantItem>().firstOrNull;
    var snippet = lastAssistant?.text ?? '';
    if (snippet.length > 120) snippet = '${snippet.substring(0, 120)}…';
    final id = ++_notificationId;
    unawaited(
      NotificationService.instance.show(
        id: id,
        title: 'pi 任务完成',
        body: snippet.isEmpty ? null : snippet,
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
      _notify('${name ?? "另一个会话"} 已完成');
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
        _syncForeground();
      } else if (prev == PiConnStatus.connected) {
        unawaited(
          NotificationService.instance.logDiagnostic(
            'bridge disconnected: next=${next.name} background=$_inBackground',
          ),
        );
        _syncForeground();
        _notify('与 bridge 的连接已断开', '将自动重连');
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
