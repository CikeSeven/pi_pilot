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
