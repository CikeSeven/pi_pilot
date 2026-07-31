import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/p2p_send_pump.dart';

/// 可控时钟:信用估速的行为完全由时间窗口决定,必须能确定性推进。
class _FakeClock {
  DateTime now = DateTime(2026, 1, 1);

  /// 显式函数引用:直接传实例会触发 implicit_call_tearoffs。
  DateTime Function() get fn => () => now;

  void advance(int ms) => now = now.add(Duration(milliseconds: ms));
}

/// 给事件循环跑够多轮。断言不得依赖 `isPumping`/`pending` 这类内部状态
/// —— 否则换回缺陷版实现时测试会“刚好”通过，根本抱不住行为。
Future<void> _settle([int turns = 50]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('P2pCreditController', () {
    test('慢链路的平坦采样后整片下降,不得被误判成高速链路', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      // 50KB/s 的真实形态:36KB 压进缓冲后长时间不动,约 720ms 后整片落下。
      credit.sample(36 * 1024);
      for (var i = 0; i < 36; i++) {
        clock.advance(20);
        credit.sample(36 * 1024); // 平坦采样:buffered 一动不动
      }
      clock.advance(20);
      credit.sample(0); // 整片排空

      // 36KB / 740ms ≈ 50KB/s。信用目标应贴住下限,而不是膨胀到数百 KB。
      // 修复前:窗口起点被每次平坦采样推到当前时刻,这一降被除以 ~20ms,
      // 算出 1.8MB/s,信用目标涨到 ~500KB —— 等于允许十几秒 bulk 排在 pong 前。
      expect(
        credit.drainRateBps,
        lessThan(400 * 1024),
        reason: '平坦采样不得重置测速窗口起点',
      );
      expect(credit.target, p2pCreditMinBytes);
    });

    test('快链路信用涨到硬顶', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      credit.sample(2000 * 1024);
      for (var i = 0; i < 30; i++) {
        clock.advance(100);
        credit.sample(1500 * 1024);
        clock.advance(100);
        credit.sample(1000 * 1024);
        clock.advance(100);
        credit.sample(2000 * 1024); // 又压入新帧
      }

      expect(credit.target, greaterThan(p2pCreditMaxBytes ~/ 2));
    });

    test('长时间完全停滞时速率估计衰减,且不跌破下限', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      // 先用快链路把估计值抬高。
      credit.sample(1000 * 1024);
      for (var i = 0; i < 10; i++) {
        clock.advance(100);
        credit.sample(500 * 1024);
        clock.advance(100);
        credit.sample(1000 * 1024);
      }
      final fast = credit.drainRateBps;
      expect(fast, greaterThan(1024 * 1024));

      // 然后链路停死:缓冲一直不动。
      for (var i = 0; i < 20; i++) {
        clock.advance(1100);
        credit.sample(1000 * 1024);
      }

      expect(credit.drainRateBps, lessThan(fast));
      expect(
        credit.drainRateBps,
        greaterThanOrEqualTo(p2pDrainRateFloorBps.toDouble()),
      );
      expect(credit.target, p2pCreditMinBytes);
    });

    test('空闲期(缓冲为0)不得衰减速率估计', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      // 先用真实排空把估计值抬起来。
      credit.sample(200 * 1024);
      for (var i = 0; i < 6; i++) {
        clock.advance(100);
        credit.sample(200 * 1024 - (i + 1) * 20 * 1024);
      }
      final warm = credit.target;
      expect(warm, greaterThan(p2pCreditMinBytes));

      // 空闲:缓冲一直是 0(没有任何东西要发)。真机实测过后果 —— 空闲期每
      // 15s 一次心跳都会让估计值对折,几分钟后 drainBps 从 128KB/s 掉到
      // 4KB/s 地板,空闲之后的第一批数据于是从最保守的信用窗口起步。
      for (var i = 0; i < 20; i++) {
        clock.advance(15000);
        credit.sample(0);
      }

      expect(
        credit.target,
        warm,
        reason: '缓冲为 0 说明没有东西要排空,不是链路慢的证据,不得衰减',
      );
    });

    test('跨越整段空闲的采样不得被当成一次有效测速', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      // 热态:真实排空把速率抬到较高值,结束时缓冲仍有残留。
      credit.sample(200 * 1024);
      for (var i = 0; i < 5; i++) {
        clock.advance(100);
        credit.sample(200 * 1024 - (i + 1) * 24 * 1024);
      }
      final warm = credit.drainRateBps;
      expect(warm, greaterThan(p2pDrainRateInitialBps.toDouble()));

      // 空闲 15s 后心跳触发一次采样,此时缓冲已排空。
      // 修复前:残留 80KB ÷ 15s 被算成 5.4KB/s,直接把估计值打到地板。
      clock.advance(15000);
      credit.sample(0);

      expect(
        credit.drainRateBps,
        warm,
        reason: '窗口跨度过大说明中间没人采样,无法知道字节是在哪一段排掉的,'
            '不得据此更新速率',
      );
    });

    test('真停滞(缓冲不为0且不下降)仍要衰减', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      credit.sample(300 * 1024);
      for (var i = 0; i < 6; i++) {
        clock.advance(100);
        credit.sample(300 * 1024 - (i + 1) * 30 * 1024);
      }
      final warm = credit.target;
      expect(warm, greaterThan(p2pCreditMinBytes));

      // 缓冲卡住不动:这是真停滞,必须衰减。
      for (var i = 0; i < 20; i++) {
        clock.advance(1100);
        credit.sample(120 * 1024);
      }

      expect(credit.target, lessThan(warm), reason: '真停滞必须衰减');
    });

    test('缓冲变大不算负排空', () {
      final clock = _FakeClock();
      final credit = P2pCreditController(clock: clock.fn);

      credit.sample(0);
      clock.advance(100);
      credit.sample(500 * 1024); // 压入新帧
      clock.advance(100);
      credit.sample(500 * 1024);

      // 没有任何真实排空,估计值应保持初值(既不涨也不因负数出乱子)。
      expect(credit.drainRateBps, p2pDrainRateInitialBps.toDouble());
    });
  });

  group('P2pSendPump', () {
    test('泵收尾窗口内入队的帧仍会被发出(不丢唤醒)', () async {
      final sent = <Object>[];
      var closed = false;
      late final P2pSendPump pump;
      var hooked = false;

      pump = P2pSendPump(
        sendFrame: (Object frame) async {
          sent.add(frame);
          // 在泵即将排空返回的那一拍入队:复现「_pump 尚未被清、队列已非空」
          // 的丢唤醒窗口。修复前这一帧会滞留到下一次 add 碰巧重启泵。
          if (!hooked) {
            hooked = true;
            scheduleMicrotask(() => pump.addNormal(<Object>['late-frame']));
          }
        },
        bufferedAmount: () async => 0,
        isClosed: () => closed,
        isSendable: () => !closed,
        onFatal: () async {
          closed = true;
        },
      );

      pump.addNormal(<Object>['first-frame']);
      await _settle();

      expect(
        sent,
        <Object>['first-frame', 'late-frame'],
        reason: '泵收尾窗口内入队的帧必须在同一轮被带走',
      );
      expect(pump.queuedFrameCount, 0);
    });

    test('control 帧插在排队的普通帧之前', () async {
      final sent = <Object>[];
      final release = Completer<void>();
      var closed = false;

      final pump = P2pSendPump(
        sendFrame: (Object frame) async {
          sent.add(frame);
          if (sent.length == 1) await release.future;
        },
        bufferedAmount: () async => 0,
        isClosed: () => closed,
        isSendable: () => !closed,
        onFatal: () async {
          closed = true;
        },
      );

      pump.addNormal(<Object>['bulk-1', 'bulk-2', 'bulk-3']);
      await Future<void>.delayed(Duration.zero);
      // 第一帧卡在发送中,此时插入控制帧。
      pump.addControl(<Object>['ping']);
      release.complete();
      await _settle();

      expect(sent.first, 'bulk-1');
      expect(sent, contains('ping'));
      expect(
        sent.indexOf('ping'),
        lessThan(sent.indexOf('bulk-3')),
        reason: '控制帧必须插在剩余批量帧之前',
      );
    });

    test('缓冲长期高于信用且无推进时判定链路死亡', () async {
      var closed = false;
      var fatal = 0;
      final clock = _FakeClock();

      final pump = P2pSendPump(
        sendFrame: (Object frame) async {},
        // 缓冲永远高于信用上限,且从不下降:没有任何推进证据。
        bufferedAmount: () async {
          clock.advance(20_000);
          return p2pCreditMaxBytes * 2;
        },
        isClosed: () => closed,
        isSendable: () => !closed,
        onFatal: () async {
          fatal++;
          closed = true;
        },
        credit: P2pCreditController(clock: clock.fn),
        creditPollInterval: Duration.zero,
      );

      pump.addNormal(<Object>['stuck']);
      await _settle();

      expect(fatal, 1);
    });

    test('通道已关闭时不启泵', () async {
      final sent = <Object>[];
      final pump = P2pSendPump(
        sendFrame: (Object frame) async => sent.add(frame),
        bufferedAmount: () async => 0,
        isClosed: () => true,
        isSendable: () => false,
        onFatal: () async {},
      );

      pump.addNormal(<Object>['never']);

      expect(pump.queuedFrameCount, 1, reason: '已关闭通道不得发出任何帧');
    });
  });

  _queueCapTests();
  _classificationTests();
}

void _queueCapTests() {
  group('P2pSendPump 队列上限', () {
    /// 永不排空的泵:bufferedAmount 恒高,泵停在信用等待里,队列只进不出。
    P2pSendPump stalledPump() => P2pSendPump(
      sendFrame: (Object frame) async {},
      bufferedAmount: () async => p2pCreditMaxBytes * 2,
      isClosed: () => false,
      isSendable: () => true,
      onFatal: () async {},
      creditPollInterval: const Duration(milliseconds: 50),
    );

    test('normal 队列越限时整批拒绝,已排队字节不变', () async {
      final pump = stalledPump();
      final chunk = 'x' * (1024 * 1024); // 1MB 一帧

      var accepted = 0;
      var bytesBeforeReject = 0;
      var rejected = false;
      for (var i = 0; i < 64; i++) {
        bytesBeforeReject = pump.normalQueuedBytes;
        // 每批 4MB,便于在 32MB 上限前后观察整批语义。
        if (!pump.addNormal(List<Object>.filled(4, chunk))) {
          rejected = true;
          break;
        }
        accepted++;
        await Future<void>.delayed(Duration.zero);
      }

      expect(rejected, isTrue, reason: '64 批 4MB 之内必须触到 32MB 上限');
      expect(accepted, greaterThan(3));
      expect(
        pump.normalQueuedBytes,
        bytesBeforeReject,
        reason: '整批被拒后排队字节数不得变化——逐帧丢弃会留下半条 transfer,'
            '接收方连 NACK 都发不出来,只能干等超时',
      );
      expect(pump.rejectedBatches, 1);
    });

    test('control 队列有独立上限,不被 normal 挤占', () async {
      final pump = stalledPump();

      // 先把 normal 堆到很大。
      pump.addNormal(List<Object>.filled(8, 'y' * (1024 * 1024)));
      await Future<void>.delayed(Duration.zero);

      // control 仍应能进(独立预算)。
      expect(pump.addControl(<Object>['{"type":"bridge_pong"}']), isTrue);
      expect(pump.controlQueuedBytes, greaterThan(0));

      // control 自己的上限也要生效。
      final big = 'z' * (128 * 1024);
      var controlRejected = false;
      for (var i = 0; i < 8; i++) {
        if (!pump.addControl(<Object>[big])) {
          controlRejected = true;
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      expect(controlRejected, isTrue, reason: 'control 队列也必须有界');
    });

    test('入队按整批记账(泵未启动时可精确观察)', () {
      // isClosed 为 true 时 kick() 直接返回,不会有帧被取走,
      // 因此这里读到的就是纯入队记账值。
      final pump = P2pSendPump(
        sendFrame: (Object frame) async {},
        bufferedAmount: () async => 0,
        isClosed: () => true,
        isSendable: () => false,
        onFatal: () async {},
      );

      expect(pump.addNormal(<Object>['a' * 1000, 'b' * 1000]), isTrue);
      expect(pump.normalQueuedBytes, 2000);
      expect(pump.addControl(<Object>['c' * 300]), isTrue);
      expect(pump.controlQueuedBytes, 300);
    });

    test('出队后字节记账回落,不会单调累积', () async {
      final sent = <Object>[];
      final pump = P2pSendPump(
        sendFrame: (Object frame) async => sent.add(frame),
        bufferedAmount: () async => 0,
        isClosed: () => false,
        isSendable: () => true,
        onFatal: () async {},
      );

      expect(pump.addNormal(<Object>['a' * 1000, 'b' * 1000]), isTrue);
      await _settle();

      expect(sent.length, 2);
      expect(pump.normalQueuedBytes, 0, reason: '发完必须扣回 0');

      // 再来一轮:确认记账不是单调累积(第二轮同样归零)。
      expect(pump.addNormal(<Object>['d' * 500]), isTrue);
      await _settle();
      expect(sent.length, 3);
      expect(pump.normalQueuedBytes, 0);
    });
  });
}

void _classificationTests() {
  group('结构化帧分类', () {
    test('内嵌 bridge_ping 的普通响应不得被判成控制帧', () {
      // 已复现过的缺陷:子串匹配看到 payload 文本里的 {"type":"bridge_ping"}
      // 就把一条 10KB 普通响应当成控制帧,直接插到控制队列最前面 ——
      // 普通载荷能冒充控制帧,优先级与预算分类就都失效了。
      final nested = jsonEncode(<String, Object>{
        'type': 'response',
        'command': 'get_entries',
        'data': '${'x' * 10000}{"type":"bridge_ping"}',
      });
      expect(p2pTopLevelType(nested), 'response');
      expect(
        p2pIsControlFrame(nested),
        isFalse,
        reason: '大响应必须走普通队列,不能因为内嵌文本被提成控制帧',
      );
    });

    test('真控制帧仍被识别', () {
      expect(
        p2pIsControlFrame(jsonEncode(<String, Object>{
          'type': 'bridge_ping',
          'echo': 1,
        })),
        isTrue,
      );
      expect(
        p2pIsControlFrame(jsonEncode(<String, Object>{
          'type': 'bridge_pong',
          'echo': 1,
        })),
        isTrue,
      );
    });

    test('超大伪控制帧降级为普通帧', () {
      // 控制帧本就只有几十到几百字节。构造一个 5KB 的 "bridge_ping" 插队,
      // 必须被字节硬上限拦下,否则控制队列可以被撑爆。
      final fat = jsonEncode(<String, Object>{
        'type': 'bridge_ping',
        'pad': 'y' * 5000,
      });
      expect(utf8.encode(fat).length, greaterThan(p2pControlFrameMaxBytes));
      expect(p2pIsControlFrame(fat), isFalse);
    });

    test('只认深度 1 的 type,异常输入不炸', () {
      // 嵌套对象里的 type 不算。
      expect(
        p2pTopLevelType(jsonEncode(<String, Object>{
          'command': 'x',
          'inner': <String, Object>{'type': 'bridge_ping'},
        })),
        isNull,
      );
      expect(p2pTopLevelType('[1,2,3]'), isNull);
      expect(p2pTopLevelType(''), isNull);
      expect(p2pTopLevelType('null'), isNull);
      // type 不是字符串。
      expect(p2pTopLevelType(jsonEncode(<String, Object>{'type': 42})), isNull);
      // 转义内容不能骗过键匹配。
      expect(
        p2pTopLevelType(jsonEncode(<String, Object>{
          'ty': 'pe":"bridge_ping',
          'type': 'response',
        })),
        'response',
      );
      // 未闭合 JSON 不得抛异常。
      expect(p2pTopLevelType('{"type":"bridge_ping'), 'bridge_ping');
      expect(() => p2pIsControlFrame('{"broken'), returnsNormally);
    });

    test('与 bridge 侧一致:阈值按 UTF-8 字节', () {
      // CJK 一字 3 字节。控制帧上限 2KB:700 个汉字是 2100+ 字节,
      // 但只有 700 多个 UTF-16 单元 —— 按字符判定会放行。
      final cjk = jsonEncode(<String, Object>{
        'type': 'bridge_ping',
        'note': '中' * 700,
      });
      expect(cjk.length, lessThan(p2pControlFrameMaxBytes));
      expect(
        utf8.encode(cjk).length,
        greaterThan(p2pControlFrameMaxBytes),
      );
      expect(p2pIsControlFrame(cjk), isFalse, reason: '必须按字节判定');
    });
  });
}
