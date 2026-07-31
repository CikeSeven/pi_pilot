import 'package:web_socket_channel/web_socket_channel.dart';

/// hub 传输通道抽象:WS 直连与 WebRTC DataChannel(打洞)两种实现的公共面。
/// hub 协议(JSON 文本帧)跑在哪种通道上,对上层完全透明。

/// msg-delta:bridge 把流式 message_update 转成增量帧(能力位门控)。
const msgDeltaCapability = 'msg-delta';

/// 以下字节预算与 bridge/src/hub_protocol.ts 的同名常量一一对应。
/// 双端保持一致才能对账:App 请求的 limitBytes 若大于 bridge 的硬上限,
/// bridge 会静默 clamp,翻页节奏就与 App 的预期不符。

/// get_entries 单页字节预算(硬上限)。50KB/s 下单页约 2s。
const maxEntriesPageBytes = 96 * 1024;

/// P2P 首屏 entries 字节预算(硬上限)。
const maxMobileEntriesBytesP2p = 128 * 1024;

/// 单条 entry 硬上限:超过就被 bridge 降级成 preview + contentRef。
const mobileEntryHardBytes = 64 * 1024;

abstract class HubChannel {
  /// 入站文本帧流。
  Stream<dynamic> get stream;

  /// 入站字节活动回调(分片/帧级)。进度型超时据此判断"传输仍在推进":
  /// 大消息分片期间完整消息很久才拼出一条,只有分片级活动能证明链路活着。
  void Function()? onActivity;

  /// 入站**数据**进度回调:与 [onActivity] 的区别是必须排除心跳与控制帧。
  ///
  /// [onActivity] 会被 bridge_pong 这类周期心跳刷新,所以它只能证明"链路活着",
  /// 不能证明"这个请求还在推进"。一个卡死的大 RPC 在心跳正常时会被无限续命,
  /// 这正是"心跳正常但数据永远不来"的根因。请求级超时必须只看这个回调。
  void Function()? onDataProgress;

  /// 建链首帧里声明的传输能力。WS 默认不需要额外能力协商。
  List<String> get transportCapabilities => const <String>[];

  /// 收到 bridge_hello 后让具体传输启用双方都支持的扩展。
  void applyHandshake(Map<String, dynamic> hello) {}

  /// 发送一帧文本。
  void add(String data);

  /// 传输层遥测快照(单行日志文本)。返回 null 表示该传输无可报指标。
  ///
  /// 这是区分「网络慢」与「应用排队慢」的唯一依据:selected pair 说明路径,
  /// 而 bufferedAmount / 队列字节 / 信用目标 / 实测排空速率说明数据卡在
  /// SCTP 缓冲还是卡在应用层队列。缺了它只能靠猜。
  Future<String?> telemetry() async => null;

  /// 关闭通道并释放底层资源。
  Future<void> close();
}

/// WebSocket 直连通道。
class WsHubChannel implements HubChannel {
  WsHubChannel(this._channel);

  final WebSocketChannel _channel;

  @override
  void Function()? onActivity;

  @override
  void Function()? onDataProgress;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  List<String> get transportCapabilities => const <String>[msgDeltaCapability];

  @override
  void applyHandshake(Map<String, dynamic> hello) {}

  @override
  void add(String data) => _channel.sink.add(data);

  /// WS 直连没有 SCTP 缓冲与应用信用窗口这类指标,局域网也基本不需要。
  @override
  Future<String?> telemetry() async => null;

  @override
  Future<void> close() => _channel.sink.close();
}
