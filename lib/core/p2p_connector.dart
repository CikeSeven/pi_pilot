import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'hub_channel.dart';
import 'p2p_chunking.dart';
import 'p2p_frame_v2.dart';
import 'p2p_send_pump.dart';
import 'p2p_signaling.dart';
import 'p2p_transfer_v2.dart';

typedef P2pCleanup = Future<void> Function();

/// 统一管理 DataChannel 的本地关闭与远端关闭,保证底层资源只释放一次。
class P2pChannelLifecycle {
  P2pChannelLifecycle({
    required P2pCleanup closeStream,
    required P2pCleanup cancelSignalingSubscription,
    required P2pCleanup closeDataChannel,
    required P2pCleanup closePeerConnection,
    required P2pCleanup closeSignaling,
  }) : _closeStream = closeStream,
       _cancelSignalingSubscription = cancelSignalingSubscription,
       _closeDataChannel = closeDataChannel,
       _closePeerConnection = closePeerConnection,
       _closeSignaling = closeSignaling;

  final P2pCleanup _closeStream;
  final P2pCleanup _cancelSignalingSubscription;
  final P2pCleanup _closeDataChannel;
  final P2pCleanup _closePeerConnection;
  final P2pCleanup _closeSignaling;
  Future<void>? _shutdownFuture;

  Future<void> onDataChannelState(RTCDataChannelState state) {
    if (state == RTCDataChannelState.RTCDataChannelClosed ||
        state == RTCDataChannelState.RTCDataChannelClosing) {
      return _shutdown(closeDataChannel: false);
    }
    return Future<void>.value();
  }

  Future<void> close() => _shutdown(closeDataChannel: true);

  Future<void> _shutdown({required bool closeDataChannel}) {
    return _shutdownFuture ??= _doShutdown(closeDataChannel: closeDataChannel);
  }

  Future<void> _doShutdown({required bool closeDataChannel}) async {
    final streamClosed = _bestEffort(_closeStream);
    await _bestEffort(_cancelSignalingSubscription);
    if (closeDataChannel) await _bestEffort(_closeDataChannel);
    await _bestEffort(_closePeerConnection);
    await _bestEffort(_closeSignaling);
    await streamClosed;
  }

  static Future<void> _bestEffort(P2pCleanup cleanup) async {
    try {
      await cleanup();
    } catch (_) {}
  }
}

/// DataChannel 通道适配:把 RTCDataChannel 包装成 [HubChannel],
/// 让 hub 协议(JSON 文本帧)原样跑在打洞通道上。
/// close 级联关闭 DataChannel、PeerConnection 与信令连接。
class RtcHubChannel implements HubChannel {
  RtcHubChannel(
    this._dc,
    this._pc,
    this._signaling,
    this._cancelSignaling, {
    TransferRetainedStore? retainedStore,
    TransferV2Assembler? assembler,
  })  : _retainedStore = retainedStore,
        _assembler = assembler {
    _lifecycle = P2pChannelLifecycle(
      closeStream: () {
        _decoder.close();
        return _controller.isClosed
            ? Future<void>.value()
            : _controller.close();
      },
      cancelSignalingSubscription: _cancelSignaling,
      closeDataChannel: _dc.close,
      closePeerConnection: _pc.close,
      closeSignaling: _signaling.close,
    );
    _dc.onMessage = (RTCDataChannelMessage message) {
      // 分片级入站活动:大消息重组期间上层很久才看到一条完整消息,
      // 进度型超时只能靠这个判断链路仍在推进。
      onActivity?.call();
      // 二进制帧 = chunk-v2;文本帧走 v1/直通路径。
      if (message.isBinary) {
        // 二进制帧一定是数据分页(ACK/NACK 也是二进制,但那是出站方向),
        // 计入请求级数据进度。
        onDataProgress?.call();
        _onBinaryFrame(message.binary);
        return;
      }
      // 心跳不算数据进度:否则一个卡死的大 RPC 会被周期 pong 无限续命。
      if (!message.text.contains('"bridge_ping"') &&
          !message.text.contains('"bridge_pong"')) {
        onDataProgress?.call();
      }
      final decoded = _decoder.add(message.text);
      if (decoded != null && !_controller.isClosed) _controller.add(decoded);
    };
    _dc.onDataChannelState = (RTCDataChannelState state) {
      unawaited(_lifecycle.onDataChannelState(state));
    };
    _sendPump = P2pSendPump(
      sendFrame: (Object frame) => _dc.send(
        frame is String
            ? RTCDataChannelMessage(frame)
            : RTCDataChannelMessage.fromBinary(frame as Uint8List),
      ),
      bufferedAmount: _dc.getBufferedAmount,
      isClosed: () => _controller.isClosed,
      isSendable: () {
        final state = _dc.state;
        return state != RTCDataChannelState.RTCDataChannelClosing &&
            state != RTCDataChannelState.RTCDataChannelClosed;
      },
      onFatal: _lifecycle.close,
    );
  }

  final RTCDataChannel _dc;
  final RTCPeerConnection _pc;
  final GuestSignaling _signaling;
  final P2pCleanup _cancelSignaling;
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final P2pChunkDecoder _decoder = P2pChunkDecoder();
  late final P2pChannelLifecycle _lifecycle;
  bool _chunkingEnabled = false;
  /// chunk-v2:二进制分页+gzip+NACK 重发+断线续传。retained/assembler
  /// 由 P2pConnector 持有(跨 channel 存活),重连后新 channel 才能凭
  /// transferId 发续传 NACK;v1 路径原样保留作能力回退。
  bool _chunkingV2Enabled = false;
  final TransferRetainedStore? _retainedStore;
  final TransferV2Assembler? _assembler;

  /// 发送队列 + 自适应在飞信用 + 泵。抽到 [P2pSendPump] 里实现:与 bridge 的
  /// `p2p_transport.ts` 互为镜像,且能脱离原生 WebRTC 层单测时序。
  /// control(bridge_ping/pong 等顺序无关小帧)优先于普通帧;
  /// 分片按 id/index 重组,控制帧插在分片之间是安全的。
  late final P2pSendPump _sendPump;

  @override
  void Function()? onActivity;

  @override
  void Function()? onDataProgress;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  List<String> get transportCapabilities =>
      const <String>[p2pChunkCapability, p2pChunkV2Capability, msgDeltaCapability];

  @override
  void applyHandshake(Map<String, dynamic> hello) {
    final capabilities = hello['capabilities'];
    _chunkingEnabled =
        capabilities is List && capabilities.contains(p2pChunkCapability);
    _chunkingV2Enabled =
        capabilities is List && capabilities.contains(p2pChunkV2Capability);
    // 断线续传:握手确认对端会 v2 后,立即报告残留 assembly 的缺失页。
    // resume 标记让对端补 BEGIN(重建元信息)+缺失页+DONE。
    if (_chunkingV2Enabled) {
      final assembler = _assembler;
      if (assembler != null) {
        for (final pending in assembler.pendingResumes()) {
          _sendBinaryControl(
            TransferV2Assembler.resumeNackFrame(
              pending.transferIdHex,
              pending.missing,
              pending.pageCount,
            ),
          );
        }
      }
    }
  }

  /// 入站二进制帧 = chunk-v2。ACK/NACK 在 channel 层处理(发送方语义),
  /// BEGIN/DATA/DONE/ABORT 喂重组器;交付的 JSON 走与 v1 相同的流。
  void _onBinaryFrame(Uint8List bytes) {
    P2pFrameV2 frame;
    try {
      frame = P2pFrameV2.decode(bytes);
    } catch (_) {
      return;
    }
    if (frame.type == P2pFrameV2Type.ack) {
      _retainedStore?.ack(transferIdHexOf(frame.transferId));
      return;
    }
    if (frame.type == P2pFrameV2Type.nack) {
      final missing =
          (frame.meta?['missing'] as List?)
              ?.whereType<num>()
              .map((value) => value.toInt())
              .toList() ??
          const <int>[];
      final resends = _retainedStore?.resendFrames(
        transferIdHexOf(frame.transferId),
        missing,
        frame.meta?['resume'] == true,
      );
      if (resends == null) {
        // 未知/已过期 transfer:回 ABORT 让接收方别傻等(走重同步)。
        _sendBinaryControl(
          P2pFrameV2(
            type: P2pFrameV2Type.abort,
            transferId: frame.transferId,
            pageCount: frame.pageCount,
            meta: const {'reason': 'unknown transfer'},
          ).encode(),
        );
        return;
      }
      if (!_sendPump.addNormal(resends)) {
        // 整批重发挤不进队列:回 ABORT,让接收方走重同步而不是干等超时。
        _sendBinaryControl(
          P2pFrameV2(
            type: P2pFrameV2Type.abort,
            transferId: frame.transferId,
            pageCount: frame.pageCount,
            meta: const {'reason': 'send queue full'},
          ).encode(),
        );
      }
      return;
    }
    final assembler = _assembler;
    if (assembler == null) return;
    final result = assembler.onFrame(bytes);
    for (final reply in result.replies) {
      _sendBinaryControl(reply);
    }
    if (result.message != null && !_controller.isClosed) {
      _controller.add(result.message!);
    }
  }

  /// ACK/NACK/ABORT 回执:极小帧直发(控制语义,不挤发送队列)。
  void _sendBinaryControl(Uint8List frame) {
    if (_controller.isClosed) return;
    try {
      unawaited(_dc.send(RTCDataChannelMessage.fromBinary(frame)));
    } catch (_) {
      // 直发失败由泵/生命周期路径收口,这里不打断入站处理。
    }
  }

  @override
  void add(String data) {
    if (_controller.isClosed) return;
    late final List<Object> frames;
    // v2 路径下记住 transferId:整条被队列拒绝时要按 id 精确撤销留存。
    String? retainedKey;
    try {
      // chunk-v2:大帧走二进制分页+gzip,留存供 NACK 重发/断线续传。
      frames =
          _chunkingV2Enabled && utf8.encode(data).length > v2DirectBytes
              ? (() {
                final transfer = encodeTransferV2(data);
                _retainedStore?.add(transfer);
                retainedKey = transferIdHexOf(transfer.transferId);
                return transfer.frames;
              })()
              : _chunkingEnabled
              ? encodeP2pFrames(data)
              : <String>[data];
    } catch (_) {
      unawaited(_lifecycle.close());
      return;
    }
    // 结构化分类:按顶层 type 判定并加 2KB 字节硬上限。
    //
    // 原来的子串匹配能被普通载荷冒充:已复现一条 10,079B 的普通响应,因为
    // payload 文本里嵌了 {"type":"bridge_ping"} 而被判成控制帧,直接插到
    // 控制队列最前面 —— 优先级与预算分类同时失效。
    final control = p2pIsControlFrame(data);
    final admitted = control
        ? _sendPump.addControl(frames)
        : _sendPump.addNormal(frames);
    if (!admitted) {
      // 整条被拒:留存里那份也要撤掉,否则对端永远不会为一条根本没发出去的
      // transfer 发 NACK,这份留存只能等 TTL 超时,白占几十 MB 预算。
      final key = retainedKey;
      if (key != null) _retainedStore?.dropTransfer(key);
    }
  }

  /// 传输层遥测:区分「网络慢」与「应用排队慢」。
  ///
  /// buffered 是已交给 SCTP 但还没发出去的字节(网络侧背压);
  /// normalQ/controlQ 是还没交给 SCTP 的应用队列字节(应用侧排队);
  /// creditTarget/drainBps 是自适应信用当前的判断依据。
  /// 慢链路上这几个数一起看才能定位瓶颈在哪一层。
  @override
  Future<String?> telemetry() async {
    int buffered;
    try {
      buffered = await _dc.getBufferedAmount();
    } catch (_) {
      buffered = -1;
    }
    final credit = _sendPump.credit;
    return 'chan{buffered:$buffered,'
        'normalQ:${_sendPump.normalQueuedBytes},'
        'controlQ:${_sendPump.controlQueuedBytes},'
        'queuedFrames:${_sendPump.queuedFrameCount},'
        'rejectedBatches:${_sendPump.rejectedBatches},'
        'creditTarget:${credit.target},'
        'drainBps:${credit.drainRateBps.round()},'
        'v2:$_chunkingV2Enabled}';
  }

  @override
  Future<void> close() => _lifecycle.close();
}

enum P2pIceMode { direct, relay }

/// 上次成功模式的持久化接口(由 settings 层实现)。
/// 命中时跳过耗时探测:relay 网络的每次重连可省 7s direct 空等。
typedef P2pIceModeCache = ({
  Future<P2pIceMode?> Function() read,
  Future<void> Function(P2pIceMode mode) onSuccess,
  Future<void> Function() onFailure,
});

const Map<String, dynamic> p2pDataChannelOfferConstraints = <String, dynamic>{
  'mandatory': <String, dynamic>{
    'OfferToReceiveAudio': false,
    'OfferToReceiveVideo': false,
  },
  'optional': <dynamic>[],
};

bool _isTurnUrl(String url) =>
    url.startsWith('turn:') || url.startsWith('turns:');

List<Map<String, dynamic>> p2pIceServersForMode(
  List<Map<String, dynamic>> servers,
  P2pIceMode mode,
) {
  final filtered = <Map<String, dynamic>>[];
  for (final server in servers) {
    final rawUrls = server['urls'];
    final candidates = rawUrls is String
        ? <Object?>[rawUrls]
        : rawUrls is List
        ? rawUrls
        : const <Object?>[];
    final urls = candidates
        .whereType<String>()
        .where(
          (url) => mode == P2pIceMode.relay
              ? _isTurnUrl(url)
              : url.startsWith('stun:'),
        )
        .toList(growable: false);
    if (urls.isEmpty) continue;
    filtered.add(<String, dynamic>{
      'urls': urls,
      if (server['username'] is String) 'username': server['username'],
      if (server['credential'] is String) 'credential': server['credential'],
    });
  }
  return List<Map<String, dynamic>>.unmodifiable(filtered);
}

bool p2pHasTurn(List<Map<String, dynamic>> servers) {
  for (final server in servers) {
    final rawUrls = server['urls'];
    final candidates = rawUrls is String
        ? <Object?>[rawUrls]
        : rawUrls is List
        ? rawUrls
        : const <Object?>[];
    if (candidates.whereType<String>().any(_isTurnUrl)) return true;
  }
  return false;
}

/// 选中候选对摘要:direct 还是 TURN 中继,吞吐差一个数量级。
///
/// 这是诊断"为什么慢"的第一现场证据。此前仓库里完全没有 getStats 插桩,
/// 线上只能靠猜;而 relay 与 direct 的可用带宽通常差 10 倍以上,分不清路径
/// 就无法判断瓶颈在网络、TURN 服务器还是应用排队。
Future<String> p2pSelectedPairSummary(
  RTCPeerConnection pc,
  P2pIceMode mode,
) async {
  try {
    final stats = await pc.getStats();
    final pairs = <String, Map<String, dynamic>>{};
    final candidates = <String, Map<String, dynamic>>{};
    final types = <String>{};
    String? transportPairId;

    for (final report in stats) {
      final values = Map<String, dynamic>.from(report.values);
      types.add(report.type);
      switch (report.type) {
        case 'candidate-pair':
        case 'googCandidatePair':
          pairs[report.id] = values;
        case 'local-candidate':
        case 'remote-candidate':
          candidates[report.id] = values;
        case 'transport':
          final id = values['selectedCandidatePairId'];
          if (id is String && id.isNotEmpty) transportPairId = id;
      }
    }

    // 多级回退。真机上首轮实测返回 pair:none —— 只认 selected/nominated
    // 太窄:不同 WebRTC 版本对「选中」的表达方式不一致(有的只在 transport
    // 上给 selectedCandidatePairId,有的用 googActiveConnection 字符串)。
    Map<String, dynamic>? pair;
    if (transportPairId != null) pair = pairs[transportPairId];
    pair ??= pairs.values.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['selected'] == true,
      orElse: () => null,
    );
    pair ??= pairs.values.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['googActiveConnection'] == 'true' || p?['googActiveConnection'] == true,
      orElse: () => null,
    );
    pair ??= pairs.values.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['nominated'] == true && p?['state'] == 'succeeded',
      orElse: () => null,
    );
    pair ??= pairs.values.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['state'] == 'succeeded',
      orElse: () => null,
    );

    if (pair == null) {
      // 仍取不到:把实际拿到的 report 类型与 pair 数量打出来,免得下一轮
      // 还要靠猜(每轮都要重装 APK,盲改代价很高)。
      return 'selected_pair{mode:${mode.name},pair:none,'
          'pairReports:${pairs.length},types:${(types.toList()..sort()).join("|")}}';
    }

    // 闭包里不依赖局部变量的类型提升:先收口成 final 非空引用。
    final selected = pair;

    // 候选类型:优先查引用的候选报告,退化到 pair 自带的内联候选。
    Map<String, dynamic>? candidateOf(String key, String fallbackKey) {
      final id = selected[key];
      if (id is String && candidates.containsKey(id)) return candidates[id];
      final inline = selected[fallbackKey];
      return inline is Map ? Map<String, dynamic>.from(inline) : null;
    }

    final local = candidateOf('localCandidateId', 'local');
    final remote = candidateOf('remoteCandidateId', 'remote');
    String typeOf(Map<String, dynamic>? c) =>
        (c?['candidateType'] ?? c?['type'] ?? '?').toString();
    String protoOf(Map<String, dynamic>? c) =>
        (c?['protocol'] ?? c?['transport'] ?? '?').toString();
    final localType = typeOf(local);
    final remoteType = typeOf(remote);
    // 任一端是 relay 就说明流量在过 TURN。取不到候选类型时退回按模式判断:
    // relay 模式下 iceTransportPolicy=relay,只可能走中继。
    final viaRelay = localType == 'relay' ||
        remoteType == 'relay' ||
        (localType == '?' && remoteType == '?' && mode == P2pIceMode.relay);
    return 'selected_pair{mode:${mode.name},'
        'local:$localType/${protoOf(local)},'
        'remote:$remoteType/${protoOf(remote)},'
        'viaRelay:$viaRelay,'
        'rttMs:${selected['currentRoundTripTime'] ?? selected['totalRoundTripTime'] ?? '?'},'
        'availOutBps:${selected['availableOutgoingBitrate'] ?? '?'},'
        'bytesSent:${selected['bytesSent'] ?? '?'},'
        'bytesRecv:${selected['bytesReceived'] ?? '?'}}';
  } catch (error) {
    return 'selected_pair{mode:${mode.name},error:${p2pErrorForWire(error)}}';
  }
}

String p2pErrorForWire(Object error) {
  final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  return text.length <= 500 ? text : text.substring(0, 500);
}

/// Trickle ICE 允许 candidate 先于 answer 到达。libjingle 要求先设置
/// remoteDescription,所以这里把早到的 candidate 保序缓存到 answer 之后。
class P2pCandidateBuffer<T> {
  final List<T> _pending = <T>[];
  bool _ready = false;

  Future<void> add(T candidate, Future<void> Function(T) apply) async {
    if (!_ready) {
      _pending.add(candidate);
      return;
    }
    await apply(candidate);
  }

  Future<void> flush(Future<void> Function(T) apply) async {
    if (_ready) return;
    _ready = true;
    for (final candidate in _pending) {
      await apply(candidate);
    }
    _pending.clear();
  }
}

/// 保证 offer 帧先发出,再按产生顺序放行本地 trickle candidate。
class P2pSignalGate<T> {
  final List<T> _pending = <T>[];
  bool _open = false;

  void add(T value, void Function(T) send) {
    if (_open) {
      send(value);
    } else {
      _pending.add(value);
    }
  }

  void open(void Function(T) send) {
    if (_open) return;
    _open = true;
    for (final value in _pending) {
      send(value);
    }
    _pending.clear();
  }
}

Future<T?> acquireP2pResource<T>({
  required Future<T> Function() acquire,
  required Future<void> Function(Object error) reportError,
  required P2pCleanup releaseOwner,
}) async {
  try {
    return await acquire();
  } catch (error) {
    try {
      await reportError(error);
    } catch (_) {}
    try {
      await releaseOwner();
    } catch (_) {}
    return null;
  }
}

/// Happy Eyeballs 式竞速:direct 先起,relay 在 [headStart] 之后并行起。
///
/// 原来是严格串行:direct 失败要先吃满整个 directTimeout(7s)才开始 relay。
/// relay 网络上每次重连都白等这 7s —— 用户看到的就是"连上很慢"。
///
/// 头启延迟的作用是保住既有语义与成本:
/// - direct 在 headStart 内成功 → relay 从未创建(不浪费 TURN 配额,
///   也不会产生一个需要清理的多余 PeerConnection);
/// - direct 更慢或失败 → relay 已经在跑,不必从零开始。
///
/// 先完成且非 null 者胜出;败者的迟到结果由 [dispose] 回收(它可能是一条
/// 已经打开的通道,不关就是资源泄漏)。
Future<T?> p2pConnectWithFallback<T>({
  required bool canRelay,
  required Future<T?> Function() direct,
  required Future<T?> Function() relay,
  Duration headStart = const Duration(milliseconds: 1200),
  Future<void> Function(T loser)? dispose,
  void Function(String line)? onLog,
}) async {
  if (!canRelay) return direct();

  final result = Completer<T?>();
  var settled = false;
  var pending = 2;
  var relayStarted = false;

  void finish(T? value, String from) {
    if (value == null) {
      // 这一路失败:只有两路都失败才算整体失败。
      pending--;
      if (pending == 0 && !settled) {
        settled = true;
        result.complete(null);
      }
      return;
    }
    if (settled) {
      // 迟到的赢家:必须回收,否则一条已打开的通道无人持有。
      onLog?.call('race_late_winner{from:$from,disposed:true}');
      if (dispose != null) unawaited(dispose(value));
      return;
    }
    settled = true;
    onLog?.call('race_winner{from:$from}');
    result.complete(value);
  }

  // direct 立刻起。
  unawaited(
    direct()
        .then((value) => finish(value, 'direct'))
        .catchError((Object _) => finish(null, 'direct')),
  );

  // relay 等头启延迟;若 direct 已经赢了就根本不创建。
  unawaited(
    Future<void>.delayed(headStart).then((_) {
      if (settled) {
        // direct 在头启窗口内已定胜负:relay 这一路不再需要。
        pending--;
        return;
      }
      relayStarted = true;
      unawaited(
        relay()
            .then((value) => finish(value, 'relay'))
            .catchError((Object _) => finish(null, 'relay')),
      );
    }),
  );

  final winner = await result.future;
  if (!relayStarted && winner != null) {
    onLog?.call('race_skipped_relay{reason:direct_won_within_head_start}');
  }
  return winner;
}

/// 打洞连接器:先以独立 PeerConnection 做短时直连尝试;困难 NAT 下再重新
/// 完成信令握手,以新的 peerId 创建 TURN-only PeerConnection。分成两个清单可避免
/// werift 等待大量不可达 host/srflx 候选,拖住已经可用的 relay 候选对。
class P2pConnector {
  P2pConnector({this.onLog});

  /// 遥测出口。
  ///
  /// 此前 connector 完全没有日志:线上"很慢"时无法判断走的是直连还是 TURN、
  /// 卡在哪个阶段、信用窗口收到多少 —— 只能猜。诊断吞吐问题的第一步必须是
  /// 先能看见路径与各阶段耗时,否则任何优化都是盲改。
  final void Function(String line)? onLog;

  void _log(String line) => onLog?.call(line);

  /// chunk-v2 的发送方留存与接收方重组:connector 级持有,跨 channel
  /// 存活,重连后新 channel 才能凭 transferId 发续传 NACK/应答重发。
  final TransferRetainedStore _retainedStore = TransferRetainedStore();
  final TransferV2Assembler _assembler = TransferV2Assembler();

  Future<HubChannel?> connect({
    required String rendezvousUrl,
    required String deviceId,
    required String secret,
    Duration directTimeout = const Duration(seconds: 7),
    Duration relayTimeout = const Duration(seconds: 20),
    Duration signalingTimeout = const Duration(seconds: 8),
    P2pIceModeCache? modeCache,
  }) async {
    final cached = modeCache != null ? await modeCache.read() : null;
    final total = Stopwatch()..start();
    _log('connect_begin{cachedMode:${cached?.name ?? 'none'}}');

    /// 统一收口:每条返回路径都记「最终走了哪条路 + 总耗时」。
    /// 缓存未命中时 direct 空等会先吃掉整个 directTimeout,总耗时是判断
    /// "慢在建链还是慢在传输"的第一分界线。
    HubChannel? done(HubChannel? channel, P2pIceMode? via) {
      _log(
        'connect_end{via:${via?.name ?? 'none'},ok:${channel != null},'
        'totalMs:${total.elapsedMilliseconds}}',
      );
      return channel;
    }

    if (cached == P2pIceMode.relay) {
      // 缓存说这台设备在 relay 网络:relay 优先,跳过 direct 空等。
      final relayResult = await _tryRelay(
        rendezvousUrl: rendezvousUrl,
        deviceId: deviceId,
        secret: secret,
        timeout: relayTimeout,
        signalingTimeout: signalingTimeout,
      );
      if (relayResult != null) {
        await modeCache?.onSuccess(P2pIceMode.relay);
        return done(relayResult, P2pIceMode.relay);
      }
      await modeCache?.onFailure();
      final directResult = await _tryDirect(
        rendezvousUrl: rendezvousUrl,
        deviceId: deviceId,
        secret: secret,
        timeout: directTimeout,
        signalingTimeout: signalingTimeout,
      );
      if (directResult != null) {
        await modeCache?.onSuccess(P2pIceMode.direct);
      }
      return done(directResult, directResult != null ? P2pIceMode.direct : null);
    }
    // 默认路径:direct 先起,relay 在头启延迟后并行起(Happy Eyeballs)。
    //
    // 原来是严格串行:direct 失败要先吃满整个 directTimeout(7s)才开始 relay。
    // relay 网络上每次重连都白等这 7s,用户看到的就是"连上很慢"。
    //
    // 缓存命中 direct 时给更长头启(3s):既然上次就是直连成功的,大概率还能成,
    // 没必要那么早去占 TURN 配额。缓存未命中时头启短(1.2s),尽快摊开两条路。
    var winnerMode = P2pIceMode.direct;
    final channel = await p2pConnectWithFallback<HubChannel>(
      canRelay: true,
      headStart: cached == P2pIceMode.direct
          ? const Duration(seconds: 3)
          : const Duration(milliseconds: 1200),
      onLog: _log,
      // 败者可能是一条已经打开的通道:不关就是资源泄漏(PeerConnection +
      // DataChannel + 信令连接都还挂着)。
      dispose: (loser) => loser.close(),
      direct: () async {
        final result = await _tryDirect(
          rendezvousUrl: rendezvousUrl,
          deviceId: deviceId,
          secret: secret,
          timeout: cached == P2pIceMode.direct
              ? const Duration(seconds: 5)
              : directTimeout,
          signalingTimeout: signalingTimeout,
        );
        if (result != null) winnerMode = P2pIceMode.direct;
        return result;
      },
      relay: () async {
        final result = await _tryRelay(
          rendezvousUrl: rendezvousUrl,
          deviceId: deviceId,
          secret: secret,
          timeout: relayTimeout,
          signalingTimeout: signalingTimeout,
        );
        if (result != null) winnerMode = P2pIceMode.relay;
        return result;
      },
    );
    if (channel == null) {
      if (cached != null) await modeCache?.onFailure();
      return done(null, null);
    }
    if (cached != winnerMode) await modeCache?.onSuccess(winnerMode);
    return done(channel, winnerMode);
  }

  Future<HubChannel?> _tryDirect({
    required String rendezvousUrl,
    required String deviceId,
    required String secret,
    required Duration timeout,
    required Duration signalingTimeout,
  }) async {
    final signaling = await GuestSignaling.connect(
      url: rendezvousUrl,
      deviceId: deviceId,
      secret: secret,
      timeout: signalingTimeout,
    );
    if (signaling == null) return null;
    return _connectAttempt(
      signaling: signaling,
      mode: P2pIceMode.direct,
      timeout: timeout,
    );
  }

  Future<HubChannel?> _tryRelay({
    required String rendezvousUrl,
    required String deviceId,
    required String secret,
    required Duration timeout,
    required Duration signalingTimeout,
  }) async {
    // 新信令会话会分配新 peerId 与新短期 TURN 凭据,迟到的直连候选
    // 无法污染 relay-only PeerConnection。
    final signaling = await GuestSignaling.connect(
      url: rendezvousUrl,
      deviceId: deviceId,
      secret: secret,
      timeout: signalingTimeout,
    );
    if (signaling == null) return null;
    if (!p2pHasTurn(signaling.iceServers)) {
      await signaling.close();
      return null;
    }
    return _connectAttempt(
      signaling: signaling,
      mode: P2pIceMode.relay,
      timeout: timeout,
    );
  }

  Future<HubChannel?> _connectAttempt({
    required GuestSignaling signaling,
    required P2pIceMode mode,
    required Duration timeout,
  }) async {
    final phase = Stopwatch()..start();
    void mark(String what) =>
        _log('phase{mode:${mode.name},$what:${phase.elapsedMilliseconds}ms}');

    Future<void> reportError(Object error) async {
      signaling.sendSignal(<String, dynamic>{
        'kind': 'client_error',
        'mode': mode.name,
        'message': p2pErrorForWire(error),
      });
      // 给 WebSocket 一个事件循环窗口交付诊断帧,随后再关闭信令会话。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    final pc = await acquireP2pResource<RTCPeerConnection>(
      acquire: () => createPeerConnection(<String, dynamic>{
        'iceServers': p2pIceServersForMode(signaling.iceServers, mode),
        if (mode == P2pIceMode.relay) 'iceTransportPolicy': 'relay',
      }),
      reportError: reportError,
      releaseOwner: signaling.close,
    );
    if (pc == null) return null;
    mark('pc_created');

    final channelReady = Completer<RTCDataChannel>();
    final localCandidates = P2pSignalGate<Map<String, dynamic>>();
    final remoteCandidates = P2pCandidateBuffer<RTCIceCandidate>();
    RTCDataChannel? channel;
    StreamSubscription<Map<String, dynamic>>? sub;
    Future<void> signalQueue = Future<void>.value();

    Future<void> stopSignaling() async {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await signalQueue;
      } catch (_) {}
    }

    try {
      // ICE/连接状态迁移:卡在 checking 还是 connected 后才慢,是两类完全
      // 不同的问题(路径不通 vs 吞吐不足),没有这条日志分不出来。
      pc.onIceConnectionState = (RTCIceConnectionState state) {
        _log(
          'ice_state{mode:${mode.name},state:${state.name},'
          'at:${phase.elapsedMilliseconds}ms}',
        );
      };
      pc.onConnectionState = (RTCPeerConnectionState state) {
        _log(
          'pc_state{mode:${mode.name},state:${state.name},'
          'at:${phase.elapsedMilliseconds}ms}',
        );
      };
      pc.onIceCandidate = (RTCIceCandidate candidate) {
        localCandidates.add(<String, dynamic>{
          'kind': 'candidate',
          'candidate': <String, dynamic>{
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }, signaling.sendSignal);
      };

      sub = signaling.signals.listen((Map<String, dynamic> data) {
        // Stream.listen 不会等待 async 回调;显式串行化,保证 answer 与 candidate
        // 严格按信令到达顺序落到 libjingle。
        signalQueue = signalQueue.then((_) async {
          try {
            switch (data['kind']) {
              case 'answer':
                final sdp = data['sdp'];
                if (sdp is! String || sdp.isEmpty) {
                  throw const FormatException('remote answer has no sdp');
                }
                await pc.setRemoteDescription(
                  RTCSessionDescription(sdp, 'answer'),
                );
                await remoteCandidates.flush(
                  (candidate) => pc.addCandidate(candidate),
                );
                mark('answer_applied');
              case 'candidate':
                final raw = data['candidate'];
                if (raw is Map<String, dynamic>) {
                  final candidate = RTCIceCandidate(
                    raw['candidate'] as String?,
                    raw['sdpMid'] as String?,
                    raw['sdpMLineIndex'] as int?,
                  );
                  await remoteCandidates.add(
                    candidate,
                    (value) => pc.addCandidate(value),
                  );
                }
            }
          } catch (error, stackTrace) {
            if (!channelReady.isCompleted) {
              channelReady.completeError(error, stackTrace);
            }
          }
        });
      });

      final dc = await pc.createDataChannel('hub', RTCDataChannelInit());
      channel = dc;
      dc.onDataChannelState = (RTCDataChannelState state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen &&
            !channelReady.isCompleted) {
          channelReady.complete(dc);
        }
      };

      final offer = await pc.createOffer(p2pDataChannelOfferConstraints);
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp == null || sdp.isEmpty) {
        throw StateError('local offer has no sdp');
      }
      signaling.sendSignal(<String, dynamic>{
        'kind': 'offer',
        'mode': mode.name,
        'sdp': sdp,
      });
      localCandidates.open(signaling.sendSignal);
      mark('offer_sent');

      final opened = await channelReady.future.timeout(timeout);
      mark('channel_open');
      // 选中候选对:direct 还是 TURN 中继,吞吐差一个数量级。
      _log(await p2pSelectedPairSummary(pc, mode));
      return RtcHubChannel(
        opened,
        pc,
        signaling,
        stopSignaling,
        retainedStore: _retainedStore,
        assembler: _assembler,
      );
    } catch (error) {
      if (error is! TimeoutException) await reportError(error);
      await stopSignaling();
      try {
        await channel?.close();
      } catch (_) {}
      try {
        await pc.close();
      } catch (_) {}
      try {
        await signaling.close();
      } catch (_) {}
      return null;
    }
  }
}
