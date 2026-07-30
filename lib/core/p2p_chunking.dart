import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const p2pChunkCapability = 'p2p-chunk-v1';
const _prefix = '~pipilot-chunk-v1~';
const _directBytes = 48 * 1024;
const _chunkBytes = 36 * 1024;
const _maxMessageBytes = 16 * 1024 * 1024;
const _maxChunks = (_maxMessageBytes + _chunkBytes - 1) ~/ _chunkBytes;
const _maxPendingMessages = 8;
const _maxPendingBytes = 32 * 1024 * 1024;
const _chunkTtl = Duration(seconds: 30);
final _random = Random.secure();

String _newMessageId() {
  final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
  return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

/// WebRTC DataChannel 对单条消息有协商上限。小帧保持原样,大帧按 UTF-8
/// 字节切分并 base64 编码,确保每个线帧明显小于 64 KiB。
List<String> encodeP2pFrames(String data) {
  final bytes = utf8.encode(data);
  if (bytes.length <= _directBytes) return <String>[data];
  if (bytes.length > _maxMessageBytes) {
    throw StateError('P2P message exceeds 16MB');
  }
  final id = _newMessageId();
  final total = (bytes.length + _chunkBytes - 1) ~/ _chunkBytes;
  return <String>[
    for (var index = 0; index < total; index++)
      '$_prefix$id:$index:$total:${base64Encode(bytes.sublist(index * _chunkBytes, min(bytes.length, (index + 1) * _chunkBytes)))}',
  ];
}

class _PendingMessage {
  _PendingMessage(this.total, this.timer)
    : parts = List<Uint8List?>.filled(total, null);

  final int total;
  final Timer timer;
  final List<Uint8List?> parts;
  int bytes = 0;
}

/// 把 P2P 传输分片还原成一条 Hub JSON 文本帧。普通帧直接透传。
class P2pChunkDecoder {
  final Map<String, _PendingMessage> _pending = <String, _PendingMessage>{};
  int _pendingBytes = 0;

  String? add(String frame) {
    if (!frame.startsWith(_prefix)) return frame;
    final rest = frame.substring(_prefix.length);
    final first = rest.indexOf(':');
    final second = first < 0 ? -1 : rest.indexOf(':', first + 1);
    final third = second < 0 ? -1 : rest.indexOf(':', second + 1);
    if (first <= 0 || second <= first || third <= second) return null;

    final id = rest.substring(0, first);
    final index = int.tryParse(rest.substring(first + 1, second));
    final total = int.tryParse(rest.substring(second + 1, third));
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
        index == null ||
        total == null ||
        total < 2 ||
        total > _maxChunks ||
        index < 0 ||
        index >= total) {
      return null;
    }

    late final Uint8List part;
    try {
      part = base64Decode(rest.substring(third + 1));
    } on FormatException {
      return null;
    }
    if (part.length > _chunkBytes) return null;

    var message = _pending[id];
    if (message == null || message.total != total) {
      if (message != null) _drop(id, message);
      if (_pending.length >= _maxPendingMessages) {
        _drop(_pending.keys.first);
      }
      late final _PendingMessage created;
      final timer = Timer(_chunkTtl, () => _drop(id, created));
      created = _PendingMessage(total, timer);
      message = created;
      _pending[id] = message;
    }

    if (message.parts[index] == null) {
      message.parts[index] = part;
      message.bytes += part.length;
      _pendingBytes += part.length;
    }
    if (message.bytes > _maxMessageBytes || _pendingBytes > _maxPendingBytes) {
      _drop(id, message);
      return null;
    }
    if (message.parts.any((value) => value == null)) return null;

    final builder = BytesBuilder(copy: false);
    for (final value in message.parts) {
      builder.add(value!);
    }
    _drop(id, message);
    try {
      return utf8.decode(builder.takeBytes());
    } on FormatException {
      return null;
    }
  }

  void close() {
    for (final id in _pending.keys.toList(growable: false)) {
      _drop(id);
    }
  }

  void _drop(String id, [_PendingMessage? expected]) {
    final message = _pending[id];
    if (message == null ||
        (expected != null && !identical(message, expected))) {
      return;
    }
    message.timer.cancel();
    _pendingBytes = max(0, _pendingBytes - message.bytes);
    _pending.remove(id);
  }
}
