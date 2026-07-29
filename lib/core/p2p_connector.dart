import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'hub_channel.dart';
import 'p2p_signaling.dart';

/// DataChannel 通道适配:把 RTCDataChannel 包装成 [HubChannel],
/// 让 hub 协议(JSON 文本帧)原样跑在打洞通道上。
/// close 级联关闭 DataChannel、PeerConnection 与信令连接。
class RtcHubChannel implements HubChannel {
  RtcHubChannel(this._dc, this._pc, this._signaling) {
    _dc.onMessage = (RTCDataChannelMessage message) {
      // hub 协议只有文本帧;二进制帧不属于本协议,丢弃。
      if (message.isBinary) return;
      if (!_controller.isClosed) _controller.add(message.text);
    };
    _dc.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        if (!_controller.isClosed) _controller.close();
      }
    };
  }

  final RTCDataChannel _dc;
  final RTCPeerConnection _pc;
  final GuestSignaling _signaling;
  final StreamController<dynamic> _controller = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void add(String data) {
    if (_controller.isClosed) return;
    unawaited(_dc.send(RTCDataChannelMessage(data)));
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
    await _dc.close().catchError((_) {});
    await _pc.close().catchError((_) {});
    await _signaling.close();
  }
}

/// 打洞连接器:信令 guest 握手 → offer/answer → ICE 连通 → DataChannel 打开。
/// 成功返回已打开的 [HubChannel];任一环节失败或超时返回 null。
///
/// v6 对 v6 没有 NAT、不需要 STUN;iceServers 留空,候选就是真实地址。
/// v4 对称 NAT 打洞(成功率差)与原生 watcher 的 P2P 都是后续档位。
class P2pConnector {
  Future<HubChannel?> connect({
    required String rendezvousUrl,
    required String deviceId,
    required String secret,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final signaling = await GuestSignaling.connect(
      url: rendezvousUrl,
      deviceId: deviceId,
      secret: secret,
      timeout: timeout,
    );
    if (signaling == null) return null;

    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[],
    });
    final channelReady = Completer<RTCDataChannel>();
    RTCDataChannel? channel;

    pc.onIceCandidate = (RTCIceCandidate candidate) {
      signaling.sendSignal(<String, dynamic>{
        'kind': 'candidate',
        'candidate': <String, dynamic>{
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    final sub = signaling.signals.listen((Map<String, dynamic> data) async {
      switch (data['kind']) {
        case 'answer':
          await pc.setRemoteDescription(
            RTCSessionDescription(data['sdp'] as String?, 'answer'),
          );
        case 'candidate':
          final candidate = data['candidate'];
          if (candidate is Map<String, dynamic>) {
            await pc.addCandidate(
              RTCIceCandidate(
                candidate['candidate'] as String?,
                candidate['sdpMid'] as String?,
                candidate['sdpMLineIndex'] as int?,
              ),
            );
          }
      }
    });

    try {
      final dc = await pc.createDataChannel('hub', RTCDataChannelInit());
      channel = dc;
      dc.onDataChannelState = (RTCDataChannelState state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen &&
            !channelReady.isCompleted) {
          channelReady.complete(dc);
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp == null || sdp.isEmpty) {
        throw StateError('local offer has no sdp');
      }
      signaling.sendSignal(<String, dynamic>{'kind': 'offer', 'sdp': sdp});

      // 超时直接抛 TimeoutException,由下面的 catch 统一清理并返回 null。
      final opened = await channelReady.future.timeout(timeout);
      return RtcHubChannel(opened, pc, signaling);
    } catch (_) {
      await sub.cancel();
      await channel?.close().catchError((_) {});
      await pc.close().catchError((_) {});
      await signaling.close();
      return null;
    }
  }
}
