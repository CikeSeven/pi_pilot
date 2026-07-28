enum PiSourceKind { desktop, headless }

bool sourceEpochChanged(SourceInfo? previous, SourceInfo? next) =>
    previous != null &&
    next != null &&
    previous.id == next.id &&
    previous.epoch != next.epoch;

class SourceInfo {
  const SourceInfo({
    required this.id,
    required this.kind,
    required this.label,
    required this.connected,
    required this.epoch,
    required this.capabilities,
    required this.ownerPresent,
    required this.ownedByYou,
    this.cwd,
    this.sessionId,
    this.sessionName,
    this.ownerExpiresAt,
  });

  factory SourceInfo.fromMap(Map<dynamic, dynamic> map) {
    final owner = map['owner'] as Map?;
    final expires = owner?['expiresAt'];
    return SourceInfo(
      id: map['id'] as String? ?? '',
      kind: map['kind'] == 'desktop'
          ? PiSourceKind.desktop
          : PiSourceKind.headless,
      label: map['label'] as String? ?? map['id'] as String? ?? 'pi',
      connected: map['connected'] == true,
      epoch: map['epoch'] as String? ?? '',
      capabilities:
          (map['capabilities'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const [],
      ownerPresent: owner?['owned'] == true,
      ownedByYou: map['ownedByYou'] == true,
      cwd: map['cwd'] as String?,
      sessionId: map['sessionId'] as String?,
      sessionName: map['sessionName'] as String?,
      ownerExpiresAt: expires is int
          ? DateTime.fromMillisecondsSinceEpoch(expires)
          : null,
    );
  }

  final String id;
  final PiSourceKind kind;
  final String label;
  final bool connected;
  final String epoch;
  final List<String> capabilities;
  final bool ownerPresent;
  final bool ownedByYou;
  final String? cwd;
  final String? sessionId;
  final String? sessionName;
  final DateTime? ownerExpiresAt;

  bool get isDesktop => kind == PiSourceKind.desktop;
  bool get isHeadless => kind == PiSourceKind.headless;
  bool supports(String command) => isHeadless || capabilities.contains(command);
}

/// 一个会话此刻"活在哪里"。
///
/// 这取代了旧的「控制者 / 观察者」二元:两端本来就可以同时在各自的会话里工作,
/// 用户需要知道的是"这个会话跑在电脑上还是 bridge 上",而不是"谁有控制权"。
enum SessionLiveness {
  /// 跑在电脑端的 pi TUI 里。
  desktop,

  /// 跑在 bridge 的进程池里。
  headless,

  /// 只在磁盘上,没有进程。打开它会即时唤醒。
  dormant,
}

class HubSession {
  const HubSession({
    required this.sessionId,
    required this.sourceId,
    required this.liveness,
    required this.connected,
    required this.streaming,
    this.cwd,
    this.name,
    this.path,
    this.timestamp,
    this.sizeBytes,
  });

  factory HubSession.fromMap(Map<dynamic, dynamic> map) => HubSession(
    sessionId: map['sessionId'] as String? ?? '',
    sourceId: map['sourceId'] as String? ?? '',
    liveness: switch (map['liveness']) {
      'desktop' => SessionLiveness.desktop,
      'headless' => SessionLiveness.headless,
      _ => SessionLiveness.dormant,
    },
    connected: map['connected'] == true,
    streaming: map['streaming'] == true,
    cwd: map['cwd'] as String?,
    name: map['name'] as String?,
    path: map['path'] as String?,
    timestamp: map['timestamp'] as String?,
    sizeBytes: map['sizeBytes'] as int?,
  );

  final String sessionId;
  final String sourceId;
  final SessionLiveness liveness;
  final bool connected;
  final bool streaming;
  final String? cwd;
  final String? name;
  final String? path;
  final String? timestamp;
  final int? sizeBytes;

  bool get isLive => liveness != SessionLiveness.dormant;
  bool get isOnDesktop => liveness == SessionLiveness.desktop;

  /// 列表里显示的标题:会话名 > 目录名 > 会话 id 前 8 位。
  String get displayName {
    final named = name;
    if (named != null && named.isNotEmpty) return named;
    final dir = cwd?.split('/').where((part) => part.isNotEmpty).lastOrNull;
    if (dir != null && dir.isNotEmpty) return dir;
    return sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
  }
}

class HubCursor {
  const HubCursor({
    required this.hubId,
    required this.sourceId,
    required this.sourceEpoch,
    required this.seq,
  });

  factory HubCursor.fromMap(Map<dynamic, dynamic> map) => HubCursor(
    hubId: map['hubId'] as String? ?? '',
    sourceId: map['sourceId'] as String? ?? '',
    sourceEpoch: map['sourceEpoch'] as String? ?? '',
    seq: map['seq'] as int? ?? 0,
  );

  final String hubId;
  final String sourceId;
  final String sourceEpoch;
  final int seq;

  Map<String, dynamic> toMap() => {
    'hubId': hubId,
    'sourceId': sourceId,
    'sourceEpoch': sourceEpoch,
    'seq': seq,
  };
}
