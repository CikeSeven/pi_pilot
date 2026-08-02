import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coordinates process-wide Android network binding during connection setup.
///
/// Android's process binding affects future sockets, so the LAN WebSocket and
/// its bridge handshake must be created while Wi-Fi is bound. The binding is
/// released before P2P signaling starts; already-created sockets keep their
/// selected route after the release.
final class LanNetworkBinding {
  LanNetworkBinding._();

  static const MethodChannel _channel = MethodChannel(
    'com.pipilot.pi_pilot/lan_network',
  );

  // bindProcessToNetwork is process-wide. This queue also keeps a P2P-only
  // connection from creating its signaling socket during another LAN bind.
  static Future<void> _openTail = Future<void>.value();

  static Future<T> serializeOpen<T>(Future<T> Function() action) {
    final result = _openTail.then((_) => action());
    _openTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// Runs [action] with future Android sockets routed over Wi-Fi when possible.
  /// Non-Android targets and unavailable platform bindings retain old behavior.
  ///
  /// [host] 必须传:原生侧要按目标地址挑能路由到它的那张 Wi-Fi。手机同时挂
  /// 两张 Wi-Fi(例如 192.168.1.x 与 10.183.39.x)时,盲选第一张会把整个进程
  /// 钉在到不了 Bridge 的网卡上,socket 创建即无路由,连 SYN 都发不出去。
  static Future<T> withWifiBinding<T>(
    Future<T> Function() action, {
    String? host,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return action();
    }

    var bound = false;
    try {
      bound =
          await _channel.invokeMethod<bool>('bindWifiForLan', {'host': host}) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('LAN Wi-Fi binding unavailable: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      return await action();
    } finally {
      if (bound) {
        try {
          await _channel.invokeMethod<void>('unbindNetwork');
        } catch (error, stackTrace) {
          debugPrint('LAN Wi-Fi unbind failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
    }
  }
}
