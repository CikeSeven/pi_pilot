import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'hub_channel.dart';

enum PiConnStatus { disconnected, connecting, connected, failed }

/// 解析主机栏输入,兼容误粘贴完整 URL / 带端口 / 带路径的情况。
/// 返回规范化后的 host 与可选 port;无法解析时返回 null。
({String host, int? port})? parseHostInput(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  // 完整 URL:http(s)://、ws(s)://host[:port]/path
  if (s.contains('://')) {
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    return (host: uri.host, port: uri.hasPort ? uri.port : null);
  }

  // 误带路径:10.0.0.1/health
  final slash = s.indexOf('/');
  if (slash >= 0) s = s.substring(0, slash).trim();

  // IPv6:[::1]:9377 或 [::1]
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end <= 1) return null;
    final host = s.substring(1, end);
    final rest = s.substring(end + 1);
    if (rest.isEmpty) return (host: host, port: null);
    if (rest.startsWith(':')) {
      final p = int.tryParse(rest.substring(1));
      if (p != null && p > 0 && p <= 65535) return (host: host, port: p);
    }
    return null;
  }

  // host:port(单冒号)
  final firstColon = s.indexOf(':');
  if (firstColon >= 0) {
    if (s.indexOf(':', firstColon + 1) >= 0) {
      // 多冒号:裸 IPv6(如 ::1),不做端口解析,直接当 host
      return (host: s, port: null);
    }
    final h = s.substring(0, firstColon).trim();
    final p = int.tryParse(s.substring(firstColon + 1));
    if (h.isEmpty) return null;
    if (p != null && p > 0 && p <= 65535) return (host: h, port: p);
    return null; // 带冒号但端口非法
  }

  if (s.isEmpty || s.contains(RegExp(r'\s'))) return null;
  return (host: s, port: null);
}

/// Thin client for the PiPilot bridge,transport-agnostic:
/// 直连时通道是 WebSocket,打洞时是 WebRTC DataChannel——协议完全一致。
///
/// 直连经 `?token=` query 鉴权;打洞经首帧 auth 鉴权。两者之后桥回的
/// 第一帧都是 `bridge_hello`;握手完成后的帧流、状态流两条路共用。
class PiConnection {
  HubChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<PiConnStatus> _status =
      StreamController<PiConnStatus>.broadcast();

  /// Decoded JSON frames from the bridge (post-handshake).
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Lifecycle status changes.
  Stream<PiConnStatus> get status => _status.stream;

  bool get isOpen => _channel != null;

  /// Returns the decoded `bridge_hello` map on success, null on failure.
  Future<Map<String, dynamic>?> connect({
    required String host,
    required int port,
    required String token,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    disconnect(notify: false);

    // 防御:主机栏可能误填完整 URL(http://…/path),先规范化
    final parsed = parseHostInput(host);
    if (parsed == null) {
      _status.add(PiConnStatus.failed);
      return null;
    }

    final WebSocketChannel channel;
    try {
      final uri = Uri(
        scheme: 'ws',
        host: parsed.host,
        port: parsed.port ?? port,
        queryParameters: <String, String>{'token': token},
      );
      channel = WebSocketChannel.connect(uri);
    } catch (_) {
      _status.add(PiConnStatus.failed);
      return null;
    }
    return _attach(WsHubChannel(channel), null, timeout);
  }

  /// 经 P2P DataChannel(打洞)接入:通道已由 P2pConnector 打开,
  /// 第一帧补 auth(等价 WS 直连的 ?token=),之后握手与消息流与直连一致。
  Future<Map<String, dynamic>?> connectViaChannel(
    HubChannel channel, {
    required String token,
    String? clientId,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    disconnect(notify: false);
    return _attach(channel, () {
      send(<String, dynamic>{
        'type': 'auth',
        'token': token,
        'clientId': ?clientId,
      });
    }, timeout);
  }

  Future<Map<String, dynamic>?> _attach(
    HubChannel channel,
    void Function()? onAttached,
    Duration timeout,
  ) async {
    _status.add(PiConnStatus.connecting);
    _channel = channel;

    final ready = Completer<Map<String, dynamic>?>();
    var handshakeDone = false;

    _sub = channel.stream.listen(
      (dynamic data) {
        Object? decoded;
        try {
          decoded = jsonDecode(data as String);
        } catch (_) {
          return; // ignore malformed frames
        }
        if (decoded is! Map<String, dynamic>) return;

        if (!handshakeDone) {
          if (decoded['type'] == 'bridge_hello') {
            handshakeDone = true;
            _status.add(PiConnStatus.connected);
            if (!ready.isCompleted) ready.complete(decoded);
          }
          return; // drop anything before the hello
        }
        _messages.add(decoded);
      },
      onError: (Object _) {
        if (!ready.isCompleted) ready.complete(null);
        _channel = null;
        _status.add(
          handshakeDone ? PiConnStatus.disconnected : PiConnStatus.failed,
        );
      },
      onDone: () {
        if (!ready.isCompleted) ready.complete(null);
        _channel = null;
        _status.add(
          handshakeDone ? PiConnStatus.disconnected : PiConnStatus.failed,
        );
      },
    );

    // 监听就位后再发首帧(P2P 的 auth):bridge 见到 auth 才回 bridge_hello。
    onAttached?.call();

    return ready.future.timeout(
      timeout,
      onTimeout: () {
        // 超时必须清理僵尸通道并广播 failed,
        // 否则状态会永远停在 connecting
        if (identical(_channel, channel)) {
          _sub?.cancel();
          _sub = null;
          _channel = null;
          channel.close();
          _status.add(PiConnStatus.failed);
        }
        return null;
      },
    );
  }

  /// 发送一帧。**返回是否真的写进了通道** —— 调用方据此决定要不要
  /// 告诉用户"没发出去",而不是让消息静静消失。
  bool send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return false;
    channel.add(jsonEncode(message));
    return true;
  }

  void disconnect({bool notify = true}) {
    _sub?.cancel();
    _sub = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      channel.close();
    }
    if (notify) _status.add(PiConnStatus.disconnected);
  }
}
