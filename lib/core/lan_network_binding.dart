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
  static Future<T> withWifiBinding<T>(Future<T> Function() action) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return action();
    }

    var bound = false;
    try {
      bound = await _channel.invokeMethod<bool>('bindWifiForLan') ?? false;
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
