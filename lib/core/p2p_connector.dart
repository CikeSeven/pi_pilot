import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'hub_channel.dart';
import 'p2p_signaling.dart';

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
  RtcHubChannel(this._dc, this._pc, this._signaling, this._cancelSignaling) {
    _lifecycle = P2pChannelLifecycle(
      closeStream: () =>
          _controller.isClosed ? Future<void>.value() : _controller.close(),
      cancelSignalingSubscription: _cancelSignaling,
      closeDataChannel: _dc.close,
      closePeerConnection: _pc.close,
      closeSignaling: _signaling.close,
    );
    _dc.onMessage = (RTCDataChannelMessage message) {
      // hub 协议只有文本帧;二进制帧不属于本协议,丢弃。
      if (message.isBinary) return;
      if (!_controller.isClosed) _controller.add(message.text);
    };
    _dc.onDataChannelState = (RTCDataChannelState state) {
      unawaited(_lifecycle.onDataChannelState(state));
    };
  }

  final RTCDataChannel _dc;
  final RTCPeerConnection _pc;
  final GuestSignaling _signaling;
  final P2pCleanup _cancelSignaling;
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  late final P2pChannelLifecycle _lifecycle;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void add(String data) {
    if (_controller.isClosed) return;
    unawaited(_dc.send(RTCDataChannelMessage(data)));
  }

  @override
  Future<void> close() => _lifecycle.close();
}

enum P2pIceMode { direct, relay }

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

Future<T?> p2pConnectWithFallback<T>({
  required bool canRelay,
  required Future<T?> Function() direct,
  required Future<T?> Function() relay,
}) async {
  final directResult = await direct();
  if (directResult != null || !canRelay) return directResult;
  return relay();
}

/// 打洞连接器:先以独立 PeerConnection 做短时直连尝试;困难 NAT 下再重新
/// 完成信令握手,以新的 peerId 创建 TURN-only PeerConnection。分成两个清单可避免
/// werift 等待大量不可达 host/srflx 候选,拖住已经可用的 relay 候选对。
class P2pConnector {
  Future<HubChannel?> connect({
    required String rendezvousUrl,
    required String deviceId,
    required String secret,
    Duration directTimeout = const Duration(seconds: 7),
    Duration relayTimeout = const Duration(seconds: 20),
    Duration signalingTimeout = const Duration(seconds: 8),
  }) async {
    final directSignaling = await GuestSignaling.connect(
      url: rendezvousUrl,
      deviceId: deviceId,
      secret: secret,
      timeout: signalingTimeout,
    );
    if (directSignaling == null) return null;

    final canRelay = p2pHasTurn(directSignaling.iceServers);
    return p2pConnectWithFallback<HubChannel>(
      canRelay: canRelay,
      direct: () => _connectAttempt(
        signaling: directSignaling,
        mode: P2pIceMode.direct,
        timeout: directTimeout,
      ),
      relay: () async {
        // 新信令会话会分配新 peerId 与新短期 TURN 凭据,迟到的直连候选
        // 无法污染 relay-only PeerConnection。
        final relaySignaling = await GuestSignaling.connect(
          url: rendezvousUrl,
          deviceId: deviceId,
          secret: secret,
          timeout: signalingTimeout,
        );
        if (relaySignaling == null) return null;
        if (!p2pHasTurn(relaySignaling.iceServers)) {
          await relaySignaling.close();
          return null;
        }
        return _connectAttempt(
          signaling: relaySignaling,
          mode: P2pIceMode.relay,
          timeout: relayTimeout,
        );
      },
    );
  }

  Future<HubChannel?> _connectAttempt({
    required GuestSignaling signaling,
    required P2pIceMode mode,
    required Duration timeout,
  }) async {
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

      final opened = await channelReady.future.timeout(timeout);
      return RtcHubChannel(opened, pc, signaling, stopSignaling);
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
