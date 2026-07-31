import 'dart:math' show Random;

/// 多设备数据模型:roster 里的已添加设备 + 局域网发现到的设备。
///
/// 两个模型的身份键刻意不同:
/// - [DeviceProfile.id] 是 **app 内部分配的稳定 id**,与 bridge 的 hubId 解耦——
///   bridge 重装后 hubId 会变,但用户不该因此丢失这台设备的配置;
/// - [DiscoveredDevice.hubId] 是 **bridge 自报的身份**,只做两件事:
///   ① DHCP 换 IP 后认出「这还是原来那台」(自愈,见 docs/multi-device-plan.md §5.3);
///   ② 发现列表里过滤掉已经在 roster 里的设备。

/// 一台设备的连接偏好。
enum DeviceTransport {
  /// 局域网直连优先,失败自动回落 P2P(与旧版单设备行为一致)。
  auto,

  /// 仅局域网直连。未配 P2P 的设备实质等价于此。
  lan,

  /// 仅 P2P 远程打洞(出门在外、或局域网被隔离时强制走信令服)。
  p2p,
}

DeviceTransport deviceTransportFromName(String? name) => switch (name) {
  'lan' => DeviceTransport.lan,
  'p2p' => DeviceTransport.p2p,
  _ => DeviceTransport.auto,
};

/// roster 里的一台已添加设备。JSON 持久化在 `devices.list`。
class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.token,
    this.transport = DeviceTransport.auto,
    this.p2pRendezvous,
    this.p2pDeviceId,
    this.p2pSecret,
    this.lastHubId,
  });

  factory DeviceProfile.fromMap(Map<String, dynamic> map) {
    final p2p = map['p2p'];
    final p2pMap = p2p is Map ? p2p.cast<String, dynamic>() : null;
    return DeviceProfile(
      id: map['id'] as String? ?? generateDeviceId(),
      name: map['name'] as String? ?? '',
      host: map['host'] as String? ?? '',
      port: map['port'] as int? ?? 9377,
      token: map['token'] as String? ?? '',
      transport: deviceTransportFromName(map['transport'] as String?),
      p2pRendezvous: p2pMap?['rendezvous'] as String?,
      p2pDeviceId: p2pMap?['deviceId'] as String?,
      p2pSecret: p2pMap?['secret'] as String?,
      lastHubId: map['lastHubId'] as String?,
    );
  }

  /// app 内稳定 id(`dev-{16hex}`),与 hubId 解耦。
  final String id;

  /// 显示名:用户可改,默认取 mDNS name 或 host。
  final String name;
  final String host;
  final int port;
  final String token;

  /// 连接偏好,默认 [DeviceTransport.auto](直连优先,P2P 回落)。
  final DeviceTransport transport;

  /// P2P 三要素,整组可空:未配置即无回落路径。
  final String? p2pRendezvous;
  final String? p2pDeviceId;
  final String? p2pSecret;

  /// 上次握手 bridge_hello 里的 hubId。DHCP 自愈的匹配依据。
  final String? lastHubId;

  bool get hasLan => host.isNotEmpty && token.isNotEmpty;

  bool get hasP2p =>
      (p2pRendezvous?.isNotEmpty ?? false) &&
      (p2pDeviceId?.isNotEmpty ?? false) &&
      (p2pSecret?.isNotEmpty ?? false);

  /// 列表副标用的传输描述:「直连」/「P2P」/「直连 · 失败转 P2P」。
  String get transportLabel => switch (transport) {
    DeviceTransport.lan => '直连',
    DeviceTransport.p2p => '打洞',
    DeviceTransport.auto => hasP2p ? '直连 · 失败转 P2P' : '直连',
  };

  DeviceProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? token,
    DeviceTransport? transport,
    String? p2pRendezvous,
    String? p2pDeviceId,
    String? p2pSecret,
    String? lastHubId,
    bool clearP2p = false,
  }) {
    return DeviceProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      token: token ?? this.token,
      transport: transport ?? this.transport,
      p2pRendezvous: clearP2p ? null : (p2pRendezvous ?? this.p2pRendezvous),
      p2pDeviceId: clearP2p ? null : (p2pDeviceId ?? this.p2pDeviceId),
      p2pSecret: clearP2p ? null : (p2pSecret ?? this.p2pSecret),
      lastHubId: lastHubId ?? this.lastHubId,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'token': token,
    'transport': transport.name,
    if (hasP2p)
      'p2p': {
        'rendezvous': ?p2pRendezvous,
        'deviceId': ?p2pDeviceId,
        'secret': ?p2pSecret,
      },
    'lastHubId': ?lastHubId,
  };
}

/// 局域网发现到的一台 bridge(mDNS 或子网扫描)。
/// 不是配置,不落盘;进 roster 时才转成 [DeviceProfile]。
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.hubId,
    required this.name,
    required this.host,
    required this.port,
  });

  /// bridge 自报身份。mDNS TXT / /health 都会带;缺失时退化为 host:port。
  final String hubId;
  final String name;
  final String host;
  final int port;

  /// 去重键:优先 hubId,否则 host:port。
  String get dedupeKey => hubId.isNotEmpty ? hubId : '$host:$port';
}

String generateDeviceId() {
  final random = Random.secure();
  final hex = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return 'dev-$hex';
}
