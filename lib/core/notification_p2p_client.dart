import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'notification_service.dart';
import 'pi_connection.dart';

/// remote_hint_v1:P2P 路径的通知协议穿梭客户端。
///
/// P2P DataChannel 由 Dart 的 PiConnection 持有,原生侧摸不到 socket;
/// 协议处理(cursor、去重、展示)又不能复制到 Dart(advisor 硬性要求)。
/// 所以这个类只做传输:
///
///   PiConnection.messages ──过滤──> MethodChannel ──> 原生引擎
///   原生引擎出站帧(subscribe/next_page/ack/receipt)──> PiConnection.send
///
/// 帧过滤只放行:bridge_hello、notification_*、以及 data.type 为
/// notification_* 的 response(首页数据包在 response.data 里,漏掉
/// cursor 会永久卡死——原生 watcher 踩过这个坑)。
///
/// 生命周期由 notification_controller 按「后台 && transport==p2p &&
/// 连接在」驱动;连接断开时自己也立刻通知原生撤 ready,不等控制器。
class NotificationP2pClient {
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<PiConnStatus>? _statusSub;
  bool _active = false;

  bool get isActive => _active;

  void start({
    required PiConnection connection,
    required String installationId,
    required bool vibrate,
  }) {
    if (_active) return;
    _active = true;
    _msgSub = connection.messages.listen(
      (frame) => _onFrame(connection, installationId, vibrate, frame),
      onError: (Object e) => debugPrint('[NotificationP2pClient] messages error: $e'),
    );
    _statusSub = connection.status.listen((status) {
      if (status != PiConnStatus.connected) {
        // 断线立刻撤 ready:否则 Dart 会继续以为原生层在负责通知。
        // stop() 由控制器按状态驱动,这里只保证 ready 不留空窗。
        NotificationService.instance.p2pNotificationClosed();
      }
    });
  }

  Future<void> _onFrame(
    PiConnection connection,
    String installationId,
    bool vibrate,
    Map<String, dynamic> frame,
  ) async {
    if (!_interesting(frame)) return;
    final result = await NotificationService.instance.p2pNotificationFrame(
      frame: jsonEncode(frame),
      installationId: installationId,
      vibrate: vibrate,
    );
    if (result == null) return;
    final outbound = result['outbound'];
    if (outbound is! List) return;
    for (final raw in outbound) {
      if (raw is! String) continue;
      try {
        connection.send(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('[NotificationP2pClient] outbound decode failed: $e');
      }
    }
  }

  bool _interesting(Map<String, dynamic> frame) {
    final type = frame['type'];
    if (type == 'bridge_hello') return true;
    if (type is String && type.startsWith('notification_')) return true;
    if (type == 'response') {
      final data = frame['data'];
      if (data is Map) {
        final dataType = data['type'];
        return dataType is String && dataType.startsWith('notification_');
      }
    }
    return false;
  }

  /// 停穿梭并通知原生撤 ready。连接断开、回前台、切回 LAN 时调用。
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _msgSub?.cancel();
    await _statusSub?.cancel();
    _msgSub = null;
    _statusSub = null;
    await NotificationService.instance.p2pNotificationClosed();
  }

  /// 完整复位(回前台):停穿梭 + 撤掉引擎弹过的通知。
  Future<void> reset() async {
    await stop();
    await NotificationService.instance.p2pNotificationReset();
  }
}
