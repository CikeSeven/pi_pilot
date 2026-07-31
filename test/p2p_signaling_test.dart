import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pi_pilot/core/p2p_connector.dart';
import 'package:pi_pilot/core/p2p_signaling.dart';
import 'package:pi_pilot/core/settings_repository.dart';
import 'package:pi_pilot/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测试内伪信令服:dart:io 原生 WebSocket 服务端,
/// 逐帧录制入站,脚本化应答(welcome/error/自定义)。
class FakeRendezvous {
  late final HttpServer _http;
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> received = [];
  void Function(WebSocket ws)? onConnect;
  void Function(WebSocket ws, Map<String, dynamic> frame)? onFrame;

  Future<String> start() async {
    _http = await HttpServer.bind('127.0.0.1', 0);
    _http.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      onConnect?.call(ws);
      ws.listen((data) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(frame);
        onFrame?.call(ws, frame);
      });
    });
    return 'ws://127.0.0.1:${_http.port}';
  }

  Future<void> stop() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await _http.close(force: true);
  }
}

void main() {
  group('pairingResponse', () {
    test('与 Node 端 sha256(nonce:secret) 逐字节一致(跨语言固定向量)', () {
      // echo -n 'abc123:s3cret' | sha256sum —— 与 rendezvous/bridge 的
      // crypto.createHash("sha256").update(`${nonce}:${secret}`) 同一算法,
      // 向量钉死防止两侧实现各自漂移。
      expect(
        pairingResponse('abc123', 's3cret'),
        'a6dbade0ff185cba1fe2bfa32680dd79e3142835833c6d84f47e478a8212c0e7',
      );
    });
  });

  group('信令地址安全', () {
    test('裸域名自动补 WSS,显式 scheme 保持原样', () {
      expect(
        normalizeP2pSignalingUrl(' signal.example.com '),
        'wss://signal.example.com',
      );
      expect(
        normalizeP2pSignalingUrl('signal.example.com:443/pipilot'),
        'wss://signal.example.com:443/pipilot',
      );
      expect(
        normalizeP2pSignalingUrl('ws://127.0.0.1:9378'),
        'ws://127.0.0.1:9378',
      );
      expect(
        normalizeP2pSignalingUrl('https://signal.example.com'),
        'https://signal.example.com',
      );
    });

    test('公网必须 wss,ws 只允许回环地址', () {
      expect(isAllowedP2pSignalingUrl('signal.example.com/p2p'), isTrue);
      expect(isAllowedP2pSignalingUrl('ws://127.0.0.1:9378'), isTrue);
      expect(isAllowedP2pSignalingUrl('ws://127.20.30.40:9378'), isTrue);
      expect(isAllowedP2pSignalingUrl('ws://localhost:9378'), isTrue);
      expect(isAllowedP2pSignalingUrl('ws://[::1]:9378'), isTrue);
      expect(isAllowedP2pSignalingUrl('ws://192.168.1.20:9378'), isFalse);
      expect(isAllowedP2pSignalingUrl('ws://signal.example.com:9378'), isFalse);
      expect(isAllowedP2pSignalingUrl('https://signal.example.com'), isFalse);
      expect(
        isAllowedP2pSignalingUrl('wss://user:pass@signal.example.com'),
        isFalse,
      );
    });

    test('GuestSignaling 在联网前拒绝公网明文地址', () async {
      expect(
        await GuestSignaling.connect(
          url: 'ws://signal.example.com:9378',
          deviceId: 'dev1',
          secret: 's',
        ),
        isNull,
      );
    });
  });

  group('ICE 尝试模式', () {
    final servers = <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:one.example:3478'],
      },
      <String, dynamic>{
        'urls': <String>['turn:relay.example:3479?transport=udp'],
        'username': 'temporary-user',
        'credential': 'temporary-credential',
      },
    ];

    test('纯 DataChannel offer 显式关闭音视频接收段', () {
      expect(p2pDataChannelOfferConstraints, <String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': false,
        },
        'optional': <dynamic>[],
      });
    });

    test('直连只用 STUN,relay 只用带凭据 TURN', () {
      expect(
        p2pIceServersForMode(servers, P2pIceMode.direct),
        <Map<String, dynamic>>[
          <String, dynamic>{
            'urls': <String>['stun:one.example:3478'],
          },
        ],
      );
      expect(
        p2pIceServersForMode(servers, P2pIceMode.relay),
        <Map<String, dynamic>>[
          <String, dynamic>{
            'urls': <String>['turn:relay.example:3479?transport=udp'],
            'username': 'temporary-user',
            'credential': 'temporary-credential',
          },
        ],
      );
    });

    test('只有 TURN URL 才启用第二阶段 relay', () {
      expect(p2pHasTurn(servers), isTrue);
      expect(
        p2pHasTurn(<Map<String, dynamic>>[
          <String, dynamic>{
            'urls': <String>['stun:one.example:3478'],
          },
        ]),
        isFalse,
      );
    });

    test('answer 前到达的 candidate 会保序缓存并在之后直接应用', () async {
      final applied = <int>[];
      final buffer = P2pCandidateBuffer<int>();
      Future<void> apply(int value) async => applied.add(value);

      await buffer.add(1, apply);
      await buffer.add(2, apply);
      expect(applied, isEmpty);

      await buffer.flush(apply);
      expect(applied, <int>[1, 2]);

      await buffer.add(3, apply);
      expect(applied, <int>[1, 2, 3]);
    });

    test('本地 candidate 会等 offer 发出后再按顺序放行', () {
      final sent = <String>[];
      final gate = P2pSignalGate<String>();

      gate.add('candidate-1', sent.add);
      gate.add('candidate-2', sent.add);
      expect(sent, isEmpty);

      sent.add('offer');
      gate.open(sent.add);
      gate.add('candidate-3', sent.add);
      expect(sent, <String>[
        'offer',
        'candidate-1',
        'candidate-2',
        'candidate-3',
      ]);
    });

    test('远端 DataChannel 关闭会幂等释放订阅、PeerConnection 与信令', () async {
      final released = <String>[];
      Future<void> mark(String name) async => released.add(name);
      final lifecycle = P2pChannelLifecycle(
        closeStream: () => mark('stream'),
        cancelSignalingSubscription: () => mark('subscription'),
        closeDataChannel: () => mark('data-channel'),
        closePeerConnection: () => mark('peer-connection'),
        closeSignaling: () => mark('signaling'),
      );

      await lifecycle.onDataChannelState(
        RTCDataChannelState.RTCDataChannelClosed,
      );
      expect(released, <String>[
        'stream',
        'subscription',
        'peer-connection',
        'signaling',
      ]);

      await lifecycle.close();
      expect(released, <String>[
        'stream',
        'subscription',
        'peer-connection',
        'signaling',
      ]);
    });

    test('PeerConnection 创建失败会报告错误并释放已认证信令', () async {
      final events = <String>[];
      final resource = await acquireP2pResource<int>(
        acquire: () async {
          events.add('create');
          throw StateError('native peer creation failed');
        },
        reportError: (error) async {
          expect(error, isA<StateError>());
          events.add('report');
        },
        releaseOwner: () async => events.add('release-signaling'),
      );

      expect(resource, isNull);
      expect(events, <String>['create', 'report', 'release-signaling']);
    });

    test('直连失败后才启动独立 relay 尝试', () async {
      final attempts = <String>[];
      final channel = await p2pConnectWithFallback<String>(
        canRelay: true,
        direct: () async {
          attempts.add('direct');
          return null;
        },
        relay: () async {
          attempts.add('relay');
          return 'relay-channel';
        },
      );

      expect(channel, 'relay-channel');
      expect(attempts, <String>['direct', 'relay']);
    });

    test('直连成功时不创建 relay 尝试', () async {
      final attempts = <String>[];
      final channel = await p2pConnectWithFallback<String>(
        canRelay: true,
        direct: () async {
          attempts.add('direct');
          return 'direct-channel';
        },
        relay: () async {
          attempts.add('relay');
          return 'relay-channel';
        },
      );

      expect(channel, 'direct-channel');
      expect(attempts, <String>['direct']);
    });

    test('direct 慢于头启时 relay 并行起跑,先到者胜出', () async {
      // 原来是严格串行:direct 失败要先吃满整个 directTimeout(7s)才开始 relay。
      // relay 网络上每次重连都白等这 7s —— 用户看到的就是"连上很慢"。
      final attempts = <String>[];
      final sw = Stopwatch()..start();
      final channel = await p2pConnectWithFallback<String>(
        canRelay: true,
        headStart: const Duration(milliseconds: 50),
        direct: () async {
          attempts.add('direct');
          // 直连很慢(模拟困难 NAT 下的空等)。
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return null;
        },
        relay: () async {
          attempts.add('relay');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return 'relay-channel';
        },
      );
      sw.stop();

      expect(channel, 'relay-channel');
      expect(attempts, <String>['direct', 'relay'], reason: '两路都应起跑');
      // 关键:不必等 direct 的 600ms 走完。串行实现下这里至少要 600ms。
      expect(
        sw.elapsedMilliseconds,
        lessThan(400),
        reason: 'relay 胜出后应立刻返回,不等 direct 空等结束(实测 ${sw.elapsedMilliseconds}ms)',
      );
    });

    test('败者的迟到通道会被回收,不泄漏', () async {
      // 竞速的代价:败者可能是一条**已经打开**的通道(PeerConnection +
      // DataChannel + 信令都还挂着)。不回收就是资源泄漏。
      final disposed = <String>[];
      final channel = await p2pConnectWithFallback<String>(
        canRelay: true,
        headStart: const Duration(milliseconds: 20),
        dispose: (loser) async => disposed.add(loser),
        direct: () async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return 'direct-late';
        },
        relay: () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return 'relay-wins';
        },
      );

      expect(channel, 'relay-wins');
      // 等 direct 那条迟到结果落地。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        disposed,
        <String>['direct-late'],
        reason: '迟到的赢家必须被 dispose 回收',
      );
    });

    test('两路都失败才算整体失败', () async {
      final attempts = <String>[];
      final channel = await p2pConnectWithFallback<String>(
        canRelay: true,
        headStart: const Duration(milliseconds: 20),
        direct: () async {
          attempts.add('direct');
          return null;
        },
        relay: () async {
          attempts.add('relay');
          return null;
        },
      );

      expect(channel, isNull);
      expect(attempts, <String>['direct', 'relay']);
    });

    test('任一路抛异常不会吞掉另一路的成功', () async {
      final channel = await p2pConnectWithFallback<String>(
        canRelay: true,
        headStart: const Duration(milliseconds: 20),
        direct: () async => throw StateError('direct blew up'),
        relay: () async => 'relay-channel',
      );

      expect(channel, 'relay-channel');
    });

    test('canRelay 为假时只走直连,不起竞速', () async {
      final attempts = <String>[];
      final channel = await p2pConnectWithFallback<String>(
        canRelay: false,
        direct: () async {
          attempts.add('direct');
          return null;
        },
        relay: () async {
          attempts.add('relay');
          return 'relay-channel';
        },
      );

      expect(channel, isNull, reason: '没有 TURN 时不得回退到 relay');
      expect(attempts, <String>['direct']);
    });

    test('回传的 WebRTC 错误去换行且限制长度', () {
      final message = p2pErrorForWire('first\nsecond${'x' * 600}');
      expect(message, isNot(contains('\n')));
      expect(message.length, 500);
      expect(message, startsWith('first second'));
    });
  });

  group('GuestSignaling', () {
    test('握手:welcome→hello(挑战应答)→ok,信令双向转发', () async {
      final server = FakeRendezvous();
      final url = await server.start();
      server.onConnect = (ws) {
        ws.add(
          jsonEncode({
            'type': 'welcome',
            'nonce': 'abc123',
            'stunUrls': [
              'stun:stun.example.test:3478',
              'turn:relay.example.test:3478',
              42,
              'stun:stun.example.test:3478',
            ],
          }),
        );
      };
      server.onFrame = (ws, frame) {
        if (frame['type'] == 'hello') {
          expect(frame['role'], 'guest');
          expect(frame['deviceId'], 'dev1');
          expect(frame['response'], pairingResponse('abc123', 's3cret'));
          // 密钥本身绝不出现在线上帧里
          expect(jsonEncode(frame).contains('s3cret'), isFalse);
          ws.add(
            jsonEncode({
              'type': 'ok',
              'peerId': 'p1',
              'iceServers': [
                {
                  'urls': ['stun:stun.example.test:3478'],
                },
                {
                  'urls': 'turn:relay.example.test:3478?transport=udp',
                  'username': 'temporary-user',
                  'credential': 'temporary-credential',
                },
                {'urls': 'turn:missing-credentials.example.test:3478'},
                {'urls': 'https://invalid.example.test'},
              ],
            }),
          );
        }
      };

      final signaling = await GuestSignaling.connect(
        url: url,
        deviceId: 'dev1',
        secret: 's3cret',
      );
      expect(signaling, isNotNull);
      expect(signaling!.peerId, 'p1');
      expect(signaling.stunUrls, ['stun:stun.example.test:3478']);
      expect(signaling.iceServers, [
        {
          'urls': ['stun:stun.example.test:3478'],
        },
        {
          'urls': ['turn:relay.example.test:3478?transport=udp'],
          'username': 'temporary-user',
          'credential': 'temporary-credential',
        },
      ]);

      // guest → host
      signaling.sendSignal({'kind': 'offer', 'sdp': 'v=0'});
      await pumpEventQueue();
      expect(
        server.received.any(
          (f) => f['type'] == 'signal' && (f['data'] as Map)['kind'] == 'offer',
        ),
        isTrue,
      );

      // host → guest
      final incoming = signaling.signals.first;
      server.sockets.first.add(
        jsonEncode({
          'type': 'signal',
          'data': {'kind': 'answer', 'sdp': 'v=1'},
        }),
      );
      expect((await incoming)['kind'], 'answer');

      await signaling.close();
      await server.stop();
    });

    test('host 不在线 / 密钥错误:error 帧让 connect 返回 null', () async {
      final server = FakeRendezvous();
      final url = await server.start();
      server.onConnect = (ws) {
        ws.add(jsonEncode({'type': 'welcome', 'nonce': 'n'}));
      };
      server.onFrame = (ws, frame) {
        if (frame['type'] == 'hello') {
          ws.add(jsonEncode({'type': 'error', 'reason': 'host_offline'}));
        }
      };
      expect(
        await GuestSignaling.connect(url: url, deviceId: 'dev1', secret: 's'),
        isNull,
      );
      await server.stop();
    });

    test('welcome 始终不来:超时返回 null 而不是挂死', () async {
      final server = FakeRendezvous();
      final url = await server.start();
      // onConnect 留空:服务端连接后一言不发。
      expect(
        await GuestSignaling.connect(
          url: url,
          deviceId: 'dev1',
          secret: 's',
          timeout: const Duration(milliseconds: 300),
        ),
        isNull,
      );
      await server.stop();
    });
  });

  group('P2P 设置', () {
    test('配置持久化往返:saveP2pConfig 后 load 原样读回', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository();
      await repo.saveP2pConfig(
        enabled: true,
        rendezvous: 'wss://signal.example.com',
        deviceId: 'home-desktop',
        secret: 'pairing-secret',
      );
      final data = await repo.load();
      expect(data.p2pEnabled, isTrue);
      expect(data.p2pRendezvous, 'wss://signal.example.com');
      expect(data.p2pDeviceId, 'home-desktop');
      expect(data.p2pSecret, 'pairing-secret');
    });

    test('hasP2p:开关加三个字段齐备才为真', () {
      const settings = AppSettings();
      expect(settings.hasP2p, isFalse);
      expect(
        settings
            .copyWith(
              p2pEnabled: true,
              p2pRendezvous: 'wss://signal.example.com',
              p2pDeviceId: 'home-desktop',
              p2pSecret: 's',
            )
            .hasP2p,
        isTrue,
      );
      // 缺密钥不算齐备
      expect(
        settings
            .copyWith(
              p2pEnabled: true,
              p2pRendezvous: 'wss://signal.example.com',
              p2pDeviceId: 'home-desktop',
            )
            .hasP2p,
        isFalse,
      );
    });
  });
}
