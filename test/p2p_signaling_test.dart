import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  group('GuestSignaling', () {
    test('握手:welcome→hello(挑战应答)→ok,信令双向转发', () async {
      final server = FakeRendezvous();
      final url = await server.start();
      server.onConnect = (ws) {
        ws.add(jsonEncode({'type': 'welcome', 'nonce': 'abc123'}));
      };
      server.onFrame = (ws, frame) {
        if (frame['type'] == 'hello') {
          expect(frame['role'], 'guest');
          expect(frame['deviceId'], 'dev1');
          expect(frame['response'], pairingResponse('abc123', 's3cret'));
          // 密钥本身绝不出现在线上帧里
          expect(jsonEncode(frame).contains('s3cret'), isFalse);
          ws.add(jsonEncode({'type': 'ok', 'peerId': 'p1'}));
        }
      };

      final signaling = await GuestSignaling.connect(
        url: url,
        deviceId: 'dev1',
        secret: 's3cret',
      );
      expect(signaling, isNotNull);
      expect(signaling!.peerId, 'p1');

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
        rendezvous: 'ws://example.com:9378',
        deviceId: 'home-desktop',
        secret: 'pairing-secret',
      );
      final data = await repo.load();
      expect(data.p2pEnabled, isTrue);
      expect(data.p2pRendezvous, 'ws://example.com:9378');
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
              p2pRendezvous: 'ws://example.com:9378',
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
              p2pRendezvous: 'ws://example.com:9378',
              p2pDeviceId: 'home-desktop',
            )
            .hasP2p,
        isFalse,
      );
    });
  });
}
