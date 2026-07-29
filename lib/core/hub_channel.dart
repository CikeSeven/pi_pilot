import 'package:web_socket_channel/web_socket_channel.dart';

/// hub 传输通道抽象:WS 直连与 WebRTC DataChannel(打洞)两种实现的公共面。
/// hub 协议(JSON 文本帧)跑在哪种通道上,对上层完全透明。
abstract class HubChannel {
  /// 入站文本帧流。
  Stream<dynamic> get stream;

  /// 发送一帧文本。
  void add(String data);

  /// 关闭通道并释放底层资源。
  Future<void> close();
}

/// WebSocket 直连通道。
class WsHubChannel implements HubChannel {
  WsHubChannel(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void add(String data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}
