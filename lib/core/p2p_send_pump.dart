import 'dart:async';
import 'dart:collection';
import 'dart:convert';

/// P2P 发送队列、自适应在飞信用与发送泵。
///
/// 从 [RtcHubChannel] 抽出来的原因有两个:一是与 bridge 的
/// `p2p_transport.ts`(CreditController + pumpSendQueue)形成可对照的镜像;
/// 二是 `RtcHubChannel` 的构造依赖真实 `RTCPeerConnection`(30+ 抽象成员)
/// 与私有构造的 `GuestSignaling`,无法在单测里 fake —— 队列/信用/泵这些
/// 纯时序逻辑必须能脱离原生层验证。
///
/// 设计要点:
/// - 单条 reliable/ordered DataChannel 上,已压入 SCTP 缓冲的字节是全序的。
///   队列分级只能决定"谁先进入缓冲",无法绕过已在缓冲中的数据,所以信用
///   窗口必须收得住,否则控制帧会被埋在 bulk 后面几十秒。
/// - 背压 = 停泵,不杀链;只有连续无推进才判定链路死亡。

/// 单片线帧上限(base64 后 48KB):信用的最小单位。
const p2pCreditMinBytes = 48 * 1024;

/// 在飞信用硬顶。
const p2pCreditMaxBytes = 2 * 1024 * 1024;

/// 信用目标 = 实测排空速率 × 这么多毫秒。
const p2pCreditTargetMs = 400;

/// 未实测前的排空速率假设。
///
/// 取 128KB/s 而非 1MB/s:首屏那几片是在完全没有测量数据时发出的,乐观初值
/// 会在慢 TURN 上一次压入 400KB(约 8s 队列),控制帧要等这 8s 才出得去。
/// 宁可从保守窗口起步,快链路几个采样就能靠 EMA 涨到硬顶。
const p2pDrainRateInitialBps = 128 * 1024;

/// 速率估计的下限:避免衰减到 0 后再也涨不回来。
const p2pDrainRateFloorBps = 4 * 1024;

/// 测速窗口的最小时长:窗口太短,单次整片下降会被除出离谱的速率。
const p2pDrainSampleMinMs = 20;

/// 测速窗口的最大时长。超过就认为窗口已失效,重置基线而不据此算速率。
///
/// 判据是「有没有人在采样」:真正在发送时,泵的背压循环每 5ms 就 sample 一次,
/// dt 不可能到秒级。dt 一大只有一种解释 —— 泵空闲了一段时间没人采样。此时拿
/// 旧 windowBuffered 与新 buffered 相减,分母是整段空闲时长,算出来的速率必然
/// 荒谬地低。
///
/// 真机实测:热态残留 80KB,空闲 15s 后心跳触发一次采样,80KB÷15s 被算成
/// 5.4KB/s,几个周期后 drainBps 就掉到 4KB/s 地板 —— 空闲之后的第一批数据
/// 于是从最保守的信用窗口起步。
const p2pDrainSampleMaxMs = 2000;

/// 缓冲完全不动这么久,就把速率估计对折(链路可能已经变慢或停了)。
const p2pDrainStallDecayMs = 1000;

/// 连续这么久没有任何字节推进才判定链路死亡(慢链路合法大消息可持续数分钟)。
const p2pNoProgressClose = Duration(seconds: 120);

/// control 队列字节上限。控制帧都是极小帧(ping/pong/ACK/NACK),
/// 正常只有几百字节在排;到 256KB 说明对端根本没在收。
const p2pControlQueueMaxBytes = 256 * 1024;

/// normal 队列字节上限。与 bridge 侧 P2P_BULK_QUEUE_MAX_BYTES 同量级:
/// 慢 TURN 上 32MB 排队已经等价于链路事实上死亡。
const p2pNormalQueueMaxBytes = 32 * 1024 * 1024;

/// 控制帧字节硬上限(与 bridge 的 P2P_CONTROL_FRAME_MAX_BYTES 对应)。
///
/// 控制帧(ping/pong/ACK/NACK)本就只有几十到几百字节。超过 2KB 的"控制帧"
/// 要么不是真控制帧,要么是被构造来插队的 —— 一律降级到普通队列。
const p2pControlFrameMaxBytes = 2 * 1024;

const _p2pControlTypes = <String>{
  'bridge_ping',
  'bridge_pong',
  'transfer_ack',
  'transfer_nack',
  'transfer_drop',
  'rpc_cancel',
};

/// 顶层 `type` 字段的值。找不到(或不是顶层字符串)返回 null。
///
/// 与 bridge 的 `topLevelType` 逻辑镜像。
///
/// 为什么不用 jsonDecode:分类发生在每一次 add 上,而快照响应可以是 MB 级 ——
/// 为了读一个字段去解析整份 JSON 太贵。这里做带深度跟踪的有界扫描。
///
/// 为什么不用子串匹配:已复现过一条 10,079B 的普通响应,因为 payload 文本里
/// 嵌了 `{"type":"bridge_ping"}` 而被判成控制帧,直接插到控制队列最前面。
/// 普通载荷能冒充控制帧,优先级与预算分类就都失效了。
String? p2pTopLevelType(String json) {
  // 扫描上限:顶层键必然在开头附近;扫过这个长度还没命中就当作无 type。
  final limit = json.length < 64 * 1024 ? json.length : 64 * 1024;
  var i = 0;
  while (i < limit && json[i] != '{') {
    if (json[i].trim().isNotEmpty) return null; // 顶层不是对象
    i++;
  }
  if (i >= limit || json[i] != '{') return null;
  i++;
  var depth = 1;
  while (i < limit) {
    final ch = json[i];
    if (ch == '"') {
      final buf = StringBuffer();
      var j = i + 1;
      while (j < json.length) {
        final c = json[j];
        if (c == r'\') {
          if (j + 1 < json.length) buf.write(json[j + 1]);
          j += 2;
          continue;
        }
        if (c == '"') break;
        buf.write(c);
        j++;
      }
      i = j + 1;
      // 只认深度 1 上的键 "type"
      if (depth == 1 && buf.toString() == 'type') {
        while (i < json.length &&
            (json[i] == ':' || json[i].trim().isEmpty)) {
          i++;
        }
        if (i >= json.length || json[i] != '"') return null;
        i++;
        final value = StringBuffer();
        while (i < json.length) {
          final c = json[i];
          if (c == r'\') {
            if (i + 1 < json.length) value.write(json[i + 1]);
            i += 2;
            continue;
          }
          if (c == '"') break;
          value.write(c);
          i++;
        }
        return value.toString();
      }
      continue;
    }
    if (ch == '{' || ch == '[') {
      depth++;
    } else if (ch == '}' || ch == ']') {
      depth--;
      if (depth == 0) return null; // 顶层对象结束,没有 type
    }
    i++;
  }
  return null;
}

/// 这一帧是否走控制队列(高优先级)。
///
/// 按顶层 type 判定并加字节硬上限,与 bridge 的 classifyFrame 控制分支一致。
bool p2pIsControlFrame(String json) {
  final type = p2pTopLevelType(json);
  if (type == null || !_p2pControlTypes.contains(type)) return false;
  return utf8.encode(json).length <= p2pControlFrameMaxBytes;
}

/// 自适应在飞信用计算器。与 bridge 端 `CreditController` 同算法。
class P2pCreditController {
  P2pCreditController({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _lastProgressAt = _clock();
  }

  final DateTime Function() _clock;

  double _rateBps = p2pDrainRateInitialBps.toDouble();

  /// 测速窗口起点:锚定在上一次真实排空,而不是上一次采样。
  DateTime? _windowAt;
  int _windowBuffered = 0;
  late DateTime _lastProgressAt;

  /// 当前在飞信用目标(字节)。
  int get target {
    final value = _rateBps * p2pCreditTargetMs / 1000;
    return value
        .clamp(p2pCreditMinBytes.toDouble(), p2pCreditMaxBytes.toDouble())
        .toInt();
  }

  /// 实测排空速率(字节/秒),用于诊断与遥测。
  double get drainRateBps => _rateBps;

  /// 距上次字节推进的时长(供"无进度杀链"判定)。
  Duration get noProgress => _clock().difference(_lastProgressAt);

  /// 成功把一帧交付底层也算推进证据。
  void noteSent() {
    _lastProgressAt = _clock();
  }

  /// 采样 bufferedAmount。
  ///
  /// 关键:测速窗口锚定在「上一次真实排空」,不是「上一次采样」。慢链路的
  /// bufferedAmount 形态是「长时间不动,然后整片下降」——若每次平坦采样都把
  /// 窗口起点推到当前时刻,那一次整片下降就会被除以最小采样间隔(~20ms),
  /// 把 50KB/s 误判成 MB/s 级。实测过的后果:36KB 在约 700ms 后落下,却被算成
  /// 1.84MB/s,信用目标涨到约 500KB,等于允许十几秒的 bulk 排在 pong 前面 ——
  /// 健康慢链路被心跳判死,进而反复重连。
  void sample(int buffered) {
    final now = _clock();
    final windowAt = _windowAt;
    if (windowAt == null) {
      _windowAt = now;
      _windowBuffered = buffered;
      _lastProgressAt = now;
      return;
    }
    // 缓冲变大 = 又压入了新帧:重置基线,别把新增字节算成「负排空」。
    if (buffered > _windowBuffered) {
      _windowAt = now;
      _windowBuffered = buffered;
      return;
    }
    final drained = _windowBuffered - buffered;
    final dt = now.difference(windowAt).inMilliseconds;
    // 排空即算推进(与测速窗口是否够长无关),供无进度杀链判定。
    if (drained > 0) _lastProgressAt = now;
    if (drained <= 0) {
      // 平坦期:不推进窗口起点,让下一次下降能拿到完整耗时。但长时间完全
      // 不动时要衰减估计值,否则会一直吃着旧的高信用。
      //
      // 只有 buffered > 0 才算「停滞」:缓冲是空的说明根本没有东西要排空,
      // 这不是链路慢的证据。真机实测过后果 —— 空闲期每 15s 一次心跳都会让
      // 估计值对折,几分钟后 drainBps 从 128KB/s 掉到 4KB/s 地板,空闲之后
      // 的第一批数据于是从最保守的信用窗口起步。
      if (buffered > 0 && dt >= p2pDrainStallDecayMs) {
        final decayed = _rateBps * 0.5;
        _rateBps = decayed < p2pDrainRateFloorBps
            ? p2pDrainRateFloorBps.toDouble()
            : decayed;
        _windowAt = now;
      } else if (buffered == 0) {
        // 空闲:把窗口起点跟上,避免下次真有数据时用一个跨越整段空闲的 dt
        // 去算速率(会把速率算得极低)。
        _windowAt = now;
      }
      return;
    }
    // 窗口跨度过大 = 中间没人采样(泵空闲过)。这不是一次有效吞吐测量:
    // 无法知道这些字节是在窗口的哪一段排掉的。重置基线,不更新速率。
    if (dt > p2pDrainSampleMaxMs) {
      _windowAt = now;
      _windowBuffered = buffered;
      return;
    }
    // 窗口还太短:先把排空字节留在窗口里累积,下次采样再算。
    if (dt < p2pDrainSampleMinMs) return;
    final instant = drained * 1000 / dt;
    _rateBps = _rateBps * 0.7 + instant * 0.3;
    _windowAt = now;
    _windowBuffered = buffered;
  }
}

/// 发送泵:control 队列优先于 normal 队列,受信用窗口约束。
///
/// 元素为 `String`(v1/文本帧)或 `Uint8List`(v2 二进制线帧),由 [sendFrame]
/// 决定如何交给底层通道。
class P2pSendPump {
  P2pSendPump({
    required Future<void> Function(Object frame) sendFrame,
    required Future<int> Function() bufferedAmount,
    required bool Function() isClosed,
    required bool Function() isSendable,
    required Future<void> Function() onFatal,
    P2pCreditController? credit,
    Duration creditPollInterval = const Duration(milliseconds: 5),
  }) : _sendFrame = sendFrame,
       _bufferedAmount = bufferedAmount,
       _isClosed = isClosed,
       _isSendable = isSendable,
       _onFatal = onFatal,
       _credit = credit ?? P2pCreditController(),
       _creditPollInterval = creditPollInterval;

  final Future<void> Function(Object frame) _sendFrame;
  final Future<int> Function() _bufferedAmount;
  final bool Function() _isClosed;
  final bool Function() _isSendable;
  final Future<void> Function() _onFatal;
  final P2pCreditController _credit;
  final Duration _creditPollInterval;

  final ListQueue<Object> _controlFrames = ListQueue<Object>();
  final ListQueue<Object> _normalFrames = ListQueue<Object>();
  int _controlBytes = 0;
  int _normalBytes = 0;
  int _rejectedBatches = 0;
  Future<void>? _pump;
  bool _pumping = false;

  P2pCreditController get credit => _credit;

  int get queuedFrameCount => _controlFrames.length + _normalFrames.length;

  /// 排队字节数,供遥测与准入判定。
  int get controlQueuedBytes => _controlBytes;
  int get normalQueuedBytes => _normalBytes;

  /// 被整批拒绝的次数(可观测计数:确认背压是否真的发生过)。
  int get rejectedBatches => _rejectedBatches;

  bool get isPumping => _pumping;

  /// 当前泵任务,仅供测试等待收敛。
  Future<void>? get pending => _pump;

  static int _frameBytes(Object frame) {
    if (frame is String) return frame.length;
    if (frame is List<int>) return frame.length;
    return 0;
  }

  /// 整批原子准入。
  ///
  /// 逐帧丢弃会留下"半条 transfer":丢掉 DONE 时接收方连 NACK 都不会发(它不
  /// 知道该等多少页),只能干等到超时;丢掉中间页又会触发一轮无谓的 NACK 放大。
  /// 所以容量判定必须在入队前对整批做一次,要么全进要么全不进。
  ///
  /// 返回 false 表示整批被拒,调用方应把失败传播出去而不是假装发出去了。
  bool _admit(ListQueue<Object> queue, Iterable<Object> frames, bool control) {
    final list = frames is List<Object> ? frames : frames.toList();
    var total = 0;
    for (final frame in list) {
      total += _frameBytes(frame);
    }
    final current = control ? _controlBytes : _normalBytes;
    final limit = control ? p2pControlQueueMaxBytes : p2pNormalQueueMaxBytes;
    if (current + total > limit) {
      _rejectedBatches++;
      return false;
    }
    queue.addAll(list);
    if (control) {
      _controlBytes += total;
    } else {
      _normalBytes += total;
    }
    kick();
    return true;
  }

  /// 返回 false = 整批被拒(队列已满)。
  bool addControl(Iterable<Object> frames) =>
      _admit(_controlFrames, frames, true);

  /// 返回 false = 整批被拒(队列已满)。
  bool addNormal(Iterable<Object> frames) =>
      _admit(_normalFrames, frames, false);

  /// 启泵。
  ///
  /// 用同步旗标 + finally 重检(与 bridge 的 `pumpSendQueue` 一致),而不是
  /// `_pump ??= _drain().whenComplete(() => _pump = null)`。后者的隐患是:泵在两
  /// 队列空时直接返回,而 `whenComplete` 要下一个微任务才清 `_pump`——落在
  /// 这个窗口里的入队会看到 `_pump != null` 而不启泵。
  ///
  /// 诚实说明:在当前 Dart 调度下我没能构造出该窗口的可复现失败——`_drain`
  /// 每帧之间的 `await Future.delayed(Duration.zero)` 是 timer 任务,队列重检必然
  /// 排在任何微任务 `add()` 之后,实际上已经关上了窗口。保留 finally 重检
  /// 是防御性加固与双端对称,不是已证实的挂死修复;真正被对照实验确认的
  /// 缺陷是 [P2pCreditController.sample] 的测速窗口(见那里的注释)。
  void kick() {
    if (_pumping) return;
    if (_isClosed()) return;
    _pumping = true;
    _pump = _run();
  }

  Future<void> _run() async {
    try {
      for (;;) {
        await _drain();
        if (_isClosed()) return;
        // 重检:泵运行期间新入队的帧必须在同一轮里被带走。
        if (_controlFrames.isEmpty && _normalFrames.isEmpty) return;
      }
    } finally {
      _pumping = false;
      _pump = null;
      // 清标志与上面重检之间仍有窗口(例如 _drain 抛错退出),再检一次补启。
      if (!_isClosed() &&
          (_controlFrames.isNotEmpty || _normalFrames.isNotEmpty)) {
        kick();
      }
    }
  }

  Future<void> _drain() async {
    try {
      while (!_isClosed()) {
        // 出队即扣减记账,与 bridge 侧 pumpSendQueue 一致。
        final Object? frame;
        if (_controlFrames.isNotEmpty) {
          frame = _controlFrames.removeFirst();
          _controlBytes -= _frameBytes(frame);
          if (_controlBytes < 0) _controlBytes = 0;
        } else if (_normalFrames.isNotEmpty) {
          frame = _normalFrames.removeFirst();
          _normalBytes -= _frameBytes(frame);
          if (_normalBytes < 0) _normalBytes = 0;
        } else {
          return;
        }
        await _waitForCredit();
        if (_isClosed()) return;
        await _sendFrame(frame);
        _credit.noteSent();
        // 帧间让一拍:让后到的控制帧有机会插在剩余分片之前。
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      await _onFatal();
    }
  }

  /// 信用制流控:SCTP 缓冲超过信用目标才等它回落,不再逐片等 0
  /// (那会把吞吐钉死在 48KB/RTT)。连续无推进才判定链路死亡。
  Future<void> _waitForCredit() async {
    for (;;) {
      if (!_isSendable()) {
        throw StateError('DataChannel closed while sending');
      }
      final buffered = await _bufferedAmount();
      _credit.sample(buffered);
      if (buffered <= _credit.target) return;
      if (_credit.noProgress > p2pNoProgressClose) {
        throw TimeoutException('DataChannel send made no progress');
      }
      await Future<void>.delayed(_creditPollInterval);
    }
  }
}
