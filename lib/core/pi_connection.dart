import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

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

/// Thin WebSocket client for the PiPilot bridge.
///
/// Auth happens via the `?token=` query param. The bridge's first frame after
/// a successful handshake is `bridge_hello`; [connect] completes with that
/// decoded frame, or `null` if the connection/auth failed.
class PiConnection {
  WebSocketChannel? _channel;
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
  }) async {
    disconnect(notify: false);
    _status.add(PiConnStatus.connecting);

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

    return ready.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        // 超时必须清理僵尸 socket 并广播 failed,
        // 否则状态会永远停在 connecting
        if (identical(_channel, channel)) {
          _sub?.cancel();
          _sub = null;
          _channel = null;
          channel.sink.close();
          _status.add(PiConnStatus.failed);
        }
        return null;
      },
    );
  }

  void send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void disconnect({bool notify = true}) {
    _sub?.cancel();
    _sub = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      channel.sink.close();
    }
    if (notify) _status.add(PiConnStatus.disconnected);
  }
}
