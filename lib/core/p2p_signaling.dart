import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 配对密钥的挑战-应答应答:sha256(nonce:secret)。
/// 密钥本身永不上行——信令服被攻破也拿不到配对密钥。
String pairingResponse(String nonce, String secret) =>
    sha256.convert(utf8.encode('$nonce:$secret')).toString();

/// 信令服 guest(手机)端会话:只负责信令收发——offer/answer/candidate
/// 以 Map 形式进出,由调用方喂给 PeerConnection;本类不感知 WebRTC,
/// 因此可以完全脱离原生层单测。
class GuestSignaling {
  GuestSignaling._(this._channel);

  final WebSocketChannel _channel;
  final StreamController<Map<String, dynamic>> _signals =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 信令服分配的 guest id(ok 帧带回)。
  String? peerId;

  bool _closed = false;

  /// host 应答的 SDP/候选(signal 帧的 data 部分)。
  Stream<Map<String, dynamic>> get signals => _signals.stream;

  bool get isClosed => _closed;

  /// 连接信令服并完成 guest 握手。设备未知/密钥错误/host 不在线/超时都返回 null。
  static Future<GuestSignaling?> connect({
    required String url,
    required String deviceId,
    required String secret,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (_) {
      return null;
    }
    final signaling = GuestSignaling._(channel);
    final ok = await signaling._handshake(deviceId, secret, timeout);
    if (!ok) {
      await channel.sink.close();
      return null;
    }
    return signaling;
  }

  Future<bool> _handshake(String deviceId, String secret, Duration timeout) {
    final completer = Completer<bool>();
    // 单订阅流在挂监听前会缓存事件,connect 后立即 listen 不会丢 welcome。
    _channel.stream.listen(
      (dynamic data) {
        Map<String, dynamic> frame;
        try {
          frame = jsonDecode(data as String) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        switch (frame['type']) {
          case 'welcome':
            _channel.sink.add(
              jsonEncode(<String, dynamic>{
                'type': 'hello',
                'role': 'guest',
                'deviceId': deviceId,
                'response': pairingResponse(
                  frame['nonce'] as String? ?? '',
                  secret,
                ),
              }),
            );
          case 'ok':
            peerId = frame['peerId'] as String?;
            if (!completer.isCompleted) completer.complete(true);
          case 'error':
            if (!completer.isCompleted) completer.complete(false);
          case 'signal':
            final payload = frame['data'];
            if (payload is Map<String, dynamic> && !_signals.isClosed) {
              _signals.add(payload);
            }
          case 'peer_left':
            _closed = true;
            if (!completer.isCompleted) completer.complete(false);
            if (!_signals.isClosed) _signals.close();
        }
      },
      onError: (Object _) {
        _closed = true;
        if (!completer.isCompleted) completer.complete(false);
        if (!_signals.isClosed) _signals.close();
      },
      onDone: () {
        _closed = true;
        if (!completer.isCompleted) completer.complete(false);
        if (!_signals.isClosed) _signals.close();
      },
    );
    return completer.future.timeout(timeout, onTimeout: () => false);
  }

  /// 向 host 转发一条信令(offer / candidate)。
  void sendSignal(Map<String, dynamic> data) {
    if (_closed) return;
    _channel.sink.add(
      jsonEncode(<String, dynamic>{'type': 'signal', 'data': data}),
    );
  }

  Future<void> close() => _channel.sink.close();
}
