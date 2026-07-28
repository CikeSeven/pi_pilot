import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notification_service.dart';
import 'pi_session.dart';
import 'settings_provider.dart';

/// 监听 pi 状态,应用在后台时发本地通知:
/// - 流式结束(任务完成,附最后一段助手输出)
/// - 扩展等待输入
/// - 连接中断
/// 回前台清除全部通知。observer 同样接收(状态事件对 observer 也广播)。
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
  int _notificationId = 0;

  bool get _inBackground => _lifecycle != AppLifecycleState.resumed;
  bool get _enabled => ref.read(settingsProvider).notificationsEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      NotificationService.instance.cancelAll();
    }
  }

  void _notify(String title, [String? body]) {
    if (!_inBackground || !_enabled) return;
    NotificationService.instance.show(
      id: ++_notificationId,
      title: title,
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 任务完成:isStreaming true → false
    ref.listen(piSessionProvider.select((s) => s.isStreaming), (prev, next) {
      if (prev == true && next == false) {
        final items = ref.read(piSessionProvider).items;
        final lastAssistant = items.reversed
            .whereType<AssistantItem>()
            .firstOrNull;
        var snippet = lastAssistant?.text ?? '';
        if (snippet.length > 120) snippet = '${snippet.substring(0, 120)}…';
        _notify('pi 任务完成', snippet.isEmpty ? null : snippet);
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

    // 连接中断(connected → connecting/failed/disconnected)
    ref.listen(piSessionProvider.select((s) => s.status), (prev, next) {
      if (prev == PiConnStatus.connected && next != PiConnStatus.connected) {
        _notify('与 bridge 的连接已断开', '将自动重连');
      }
    });

    return widget.child;
  }
}
