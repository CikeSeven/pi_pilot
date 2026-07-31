import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// 配对密钥通过强制 TLS/WSS 传输,由信令服校验策略并在房间内比较摘要。
/// 信令服不落盘、不记录密钥;公网明文 ws 仍被客户端拒绝。
const p2pDeviceIdMinLength = 3;
const p2pDeviceIdMaxLength = 64;
const p2pPairingKeyMinLength = 16;
const p2pPairingKeyMaxLength = 128;

final _explicitUrlScheme = RegExp(
  r'^[a-z][a-z0-9+.-]*://',
  caseSensitive: false,
);
final _p2pDeviceIdPattern = RegExp(r'^[A-Za-z0-9._-]{3,64}$');

/// 设备名是信令服中的临时房间标识,仅允许跨端一致的安全字符集。
bool isValidP2pDeviceId(String value) => _p2pDeviceIdPattern.hasMatch(value);

/// 配对 Key 必须是 16-128 位可打印 ASCII,且至少包含四类字符中的三类。
bool isValidP2pPairingKey(String value) {
  if (value.length < p2pPairingKeyMinLength ||
      value.length > p2pPairingKeyMaxLength) {
    return false;
  }
  var classes = 0;
  var hasLowercase = false;
  var hasUppercase = false;
  var hasDigit = false;
  var hasSymbol = false;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x21 || codeUnit > 0x7e) return false;
    if (codeUnit >= 0x61 && codeUnit <= 0x7a) {
      hasLowercase = true;
    } else if (codeUnit >= 0x41 && codeUnit <= 0x5a) {
      hasUppercase = true;
    } else if (codeUnit >= 0x30 && codeUnit <= 0x39) {
      hasDigit = true;
    } else {
      hasSymbol = true;
    }
  }
  if (hasLowercase) classes++;
  if (hasUppercase) classes++;
  if (hasDigit) classes++;
  if (hasSymbol) classes++;
  return classes >= 3;
}

/// 裸域名默认走 WSS;显式 scheme 保留给后续安全校验。
String normalizeP2pSignalingUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || _explicitUrlScheme.hasMatch(trimmed)) return trimmed;
  return 'wss://$trimmed';
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final octets = normalized.split('.').map(int.tryParse).toList();
  return octets.length == 4 &&
      octets.first == 127 &&
      octets.every((part) => part != null && part >= 0 && part <= 255);
}

/// 公网信令必须由 TLS 认证;明文 ws 只允许本机测试。
bool isAllowedP2pSignalingUrl(String value) {
  final uri = Uri.tryParse(normalizeP2pSignalingUrl(value));
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  if (uri.scheme == 'wss') return true;
  return uri.scheme == 'ws' && _isLoopbackHost(uri.host);
}

List<String> _normalizeStunUrls(Object? value) {
  if (value is! List) return const [];
  final urls = <String>[];
  final seen = <String>{};
  for (final item in value) {
    if (item is! String) continue;
    final url = item.trim();
    if (!url.startsWith('stun:') || url.length > 512 || !seen.add(url)) {
      continue;
    }
    urls.add(url);
    if (urls.length == 4) break;
  }
  return List.unmodifiable(urls);
}

List<Map<String, dynamic>> _normalizeIceServers(Object? value) {
  if (value is! List) return const [];
  final servers = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map) continue;
    final rawUrls = item['urls'];
    final candidates = rawUrls is String
        ? <Object?>[rawUrls]
        : rawUrls is List
        ? rawUrls
        : const <Object?>[];
    final urls = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (candidate is! String) continue;
      final url = candidate.trim();
      if (url.length > 512 ||
          (!url.startsWith('stun:') &&
              !url.startsWith('turn:') &&
              !url.startsWith('turns:')) ||
          !seen.add(url)) {
        continue;
      }
      urls.add(url);
      if (urls.length == 8) break;
    }
    if (urls.isEmpty) continue;
    final hasTurn = urls.any(
      (url) => url.startsWith('turn:') || url.startsWith('turns:'),
    );
    final username = item['username'];
    final credential = item['credential'];
    if (hasTurn &&
        (username is! String ||
            username.isEmpty ||
            credential is! String ||
            credential.isEmpty)) {
      continue;
    }
    servers.add(<String, dynamic>{
      'urls': List<String>.unmodifiable(urls),
      if (username is String && username.isNotEmpty) 'username': username,
      if (credential is String && credential.isNotEmpty)
        'credential': credential,
    });
    if (servers.length == 4) break;
  }
  return List<Map<String, dynamic>>.unmodifiable(servers);
}

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

  /// 信令服下发的 STUN 地址,供旧版信令服兼容。
  List<String> stunUrls = const [];

  /// 配对通过后下发的 ICE 配置;TURN 凭据是短期值。
  List<Map<String, dynamic>> iceServers = const [];

  bool _closed = false;

  /// host 应答的 SDP/候选(signal 帧的 data 部分)。
  Stream<Map<String, dynamic>> get signals => _signals.stream;

  bool get isClosed => _closed;

  /// 连接信令服并完成 guest 握手。Key 不合规/不匹配/host 不在线/超时都返回 null。
  static Future<GuestSignaling?> connect({
    required String url,
    required String deviceId,
    required String secret,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final normalizedUrl = normalizeP2pSignalingUrl(url);
    if (!isAllowedP2pSignalingUrl(normalizedUrl) ||
        !isValidP2pDeviceId(deviceId) ||
        !isValidP2pPairingKey(secret)) {
      return null;
    }
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(normalizedUrl));
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
            stunUrls = _normalizeStunUrls(frame['stunUrls']);
            iceServers = stunUrls.isEmpty
                ? const []
                : <Map<String, dynamic>>[
                    <String, dynamic>{'urls': stunUrls},
                  ];
            _channel.sink.add(
              jsonEncode(<String, dynamic>{
                'type': 'hello',
                'role': 'guest',
                'deviceId': deviceId,
                'secret': secret,
              }),
            );
          case 'ok':
            final authenticatedServers = _normalizeIceServers(
              frame['iceServers'],
            );
            if (authenticatedServers.isNotEmpty) {
              iceServers = authenticatedServers;
            }
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
