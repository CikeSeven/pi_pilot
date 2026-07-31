import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'device_models.dart';

/// 局域网设备发现:mDNS 为主,子网 `/health` 扫描兜底。
///
/// 发现只解决「找得到」——结果里**不含 token**,
/// 「连得上」仍要走添加流程输入配对 token(见 device_edit_sheet)。
abstract class LanDiscovery {
  /// 去重后的在线设备列表。每次集合变化发一份快照。
  Stream<List<DiscoveredDevice>> get devices;

  Future<void> start();

  Future<void> stop();

  /// 手动重扫:清掉缓存结果,立即重新发现一轮。
  /// mDNS 是持续发现,没有「扫完了」事件,这里语义是「从头再来」。
  Future<void> rescan();

  /// 按平台选实现:
  /// - Android / iOS:系统 NSD(bonsoir) + Wi-Fi `/health` 单次兜底扫描;
  /// - macOS:系统 NSD(bonsoir);
  /// - Windows / Linux:子网扫描;
  /// - Web:空实现(浏览器无 mDNS,/health 扫描会被 CORS 拦)。
  static LanDiscovery platform({int scanPort = 9377}) {
    if (kIsWeb) return NoopLanDiscovery();
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return CompositeLanDiscovery([
          BonsoirLanDiscovery(),
          SubnetScanLanDiscovery(
            port: scanPort,
            wifiOnly: true,
            interval: null,
          ),
        ]);
      case TargetPlatform.macOS:
        return BonsoirLanDiscovery();
      default:
        return SubnetScanLanDiscovery(port: scanPort);
    }
  }
}

/// 空实现:不产生任何发现结果。
class NoopLanDiscovery implements LanDiscovery {
  @override
  Stream<List<DiscoveredDevice>> get devices => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> rescan() async {}
}

/// 合并多个发现源。前面的 source 优先保留其名称和 TXT 元数据。
class CompositeLanDiscovery implements LanDiscovery {
  CompositeLanDiscovery(this._delegates);

  final List<LanDiscovery> _delegates;
  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<LanDiscovery, List<DiscoveredDevice>> _snapshots = {};
  final List<StreamSubscription<List<DiscoveredDevice>>> _subscriptions = [];
  bool _started = false;

  @override
  Stream<List<DiscoveredDevice>> get devices => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final delegate in _delegates) {
      _subscriptions.add(
        delegate.devices.listen((devices) {
          _snapshots[delegate] = devices;
          _emit();
        }),
      );
    }
    await Future.wait([
      for (final delegate in _delegates) _run(delegate.start),
    ]);
  }

  @override
  Future<void> rescan() async {
    await Future.wait([
      for (final delegate in _delegates) _run(delegate.rescan),
    ]);
  }

  @override
  Future<void> stop() async {
    _started = false;
    await Future.wait([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    _subscriptions.clear();
    _snapshots.clear();
    await Future.wait([for (final delegate in _delegates) _run(delegate.stop)]);
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      debugPrint('LAN discovery delegate unavailable: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _emit() {
    if (_controller.isClosed) return;
    final merged = <String, DiscoveredDevice>{};
    for (final delegate in _delegates) {
      for (final device in _snapshots[delegate] ?? const <DiscoveredDevice>[]) {
        merged.putIfAbsent(device.dedupeKey, () => device);
      }
    }
    _controller.add(merged.values.toList(growable: false));
  }
}

/// mDNS 发现:监听 `_pipilot._tcp`,resolve 后从 TXT 取 hubId。
class BonsoirLanDiscovery implements LanDiscovery {
  static const String serviceType = '_pipilot._tcp';

  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();

  /// dedupeKey → 设备。靠 bonsoir 的 lost 事件淘汰,无需 TTL。
  final Map<String, DiscoveredDevice> _found = {};

  /// service.name → dedupeKey,lost 事件不带 host,只能按 name 反查。
  final Map<String, String> _keyByServiceName = {};

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  @override
  Stream<List<DiscoveredDevice>> get devices => _controller.stream;

  @override
  Future<void> start() async {
    if (_discovery != null) return;
    final discovery = BonsoirDiscovery(type: serviceType);
    // ready 之后 eventStream 才有值(bonsoir 5.x 的约定)。
    await discovery.ready;
    _sub = discovery.eventStream?.listen(_onEvent);
    await discovery.start();
    _discovery = discovery;
  }

  @override
  Future<void> rescan() async {
    // 没 start 过就没有可重扫的。清缓存 + 重建底层 discovery:
    // 期间已消失的设备靠重新 found/lost 收敛,广播 controller 不动,
    // 上层(DeviceManager)的订阅保持有效。
    if (_discovery == null) return;
    _found.clear();
    _keyByServiceName.clear();
    _emit();
    await stop();
    await start();
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    final service = event.service;
    switch (event.type) {
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        // found 只是「看到名字」,host/TXT 要 resolve 之后才有。
        service?.resolve(_discovery!.serviceResolver);
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        if (service is! ResolvedBonsoirService) return;
        // bonjour-service 会把宿主机所有 Docker/VPN 地址也放进 A 记录,
        // Android NSD 可能随机解析到不可达地址。新版 Bridge 在 TXT 中明确
        // 广播物理 LAN IPv4;旧版没有该字段时仍回退系统解析结果。
        final host =
            _advertisedLanIpv4(service.attributes['ipv4']) ?? service.host;
        if (host == null || host.isEmpty || service.port <= 0) return;
        final device = DiscoveredDevice(
          hubId: service.attributes['hubId'] ?? '',
          name: service.name,
          host: host,
          port: service.port,
        );
        _found[device.dedupeKey] = device;
        _keyByServiceName[service.name] = device.dedupeKey;
        _emit();
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        if (service == null) return;
        final key = _keyByServiceName.remove(service.name);
        if (key != null && _found.remove(key) != null) _emit();
      default:
        break;
    }
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(_found.values.toList(growable: false));
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) await discovery.stop();
  }
}

String? _advertisedLanIpv4(String? value) {
  if (value == null) return null;
  final address = InternetAddress.tryParse(value.trim());
  if (address == null || address.type != InternetAddressType.IPv4) return null;
  final octets = address.rawAddress;
  final first = octets[0];
  final second = octets[1];
  final isPrivate =
      first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
  return isPrivate ? address.address : null;
}

/// 子网扫描兜底:枚举本机所在私网 /24,并发探测 `http://{ip}:9377/health`。
///
/// `/health` 无鉴权但只暴露 hubId/cwd 等非机密信息,正好够认出一台 bridge。
/// 代价是扫不出非默认端口的实例——桌面端兜底,可接受。
class SubnetScanLanDiscovery implements LanDiscovery {
  SubnetScanLanDiscovery({
    this.port = 9377,
    this.interval = const Duration(seconds: 30),
    this.wifiOnly = false,
  });

  final int port;

  /// null 表示只在 start/rescan 时扫描,适合移动端省电。
  final Duration? interval;

  /// 仅扫描 Wi-Fi 网络接口,避免移动端误扫蜂窝/VPN 私网段。
  final bool wifiOnly;

  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();
  Timer? _timer;
  bool _scanning = false;
  bool _stopped = false;
  bool _started = false;

  @override
  Stream<List<DiscoveredDevice>> get devices => _controller.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _stopped = false;
    unawaited(_scanOnce());
    final interval = this.interval;
    if (interval != null) {
      _timer = Timer.periodic(interval, (_) => unawaited(_scanOnce()));
    }
  }

  Future<void> _scanOnce() async {
    if (_scanning || _stopped) return;
    _scanning = true;
    // 一轮扫描共享一个 HttpClient,避免 254 次建联各开一份连接池。
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 400);
    try {
      final subnets = await _localSubnets();
      final found = <String, DiscoveredDevice>{};
      await Future.wait([
        for (final subnet in subnets) _scanSubnet(client, subnet, found),
      ]);
      if (!_stopped && !_controller.isClosed) {
        _controller.add(found.values.toList(growable: false));
      }
    } finally {
      client.close(force: true);
      _scanning = false;
    }
  }

  /// 本机 IPv4 私网段的 /24 前缀(dart:io 拿不到掩码,按 /24 假设)。
  Future<List<String>> _localSubnets() async {
    final prefixes = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        if (wifiOnly && !_isWifiInterface(iface.name)) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final first = int.tryParse(parts[0]) ?? 0;
          final second = int.tryParse(parts[1]) ?? 0;
          // 只扫私网段,公网网卡不碰。
          final isPrivate =
              first == 10 ||
              (first == 172 && second >= 16 && second <= 31) ||
              (first == 192 && second == 168);
          if (isPrivate) prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    } catch (_) {
      // 拿不到网卡列表就当做没有子网,一轮空扫。
    }
    return prefixes.toList(growable: false);
  }

  Future<void> _scanSubnet(
    HttpClient client,
    String prefix,
    Map<String, DiscoveredDevice> found,
  ) async {
    // 64 并发一批,整段扫完约 4 批、每批最坏 ~600ms。
    const concurrency = 64;
    final hosts = List.generate(254, (i) => '$prefix.${i + 1}');
    for (var i = 0; i < hosts.length; i += concurrency) {
      if (_stopped) return;
      final batch = hosts.sublist(i, min(i + concurrency, hosts.length));
      await Future.wait(
        batch.map((host) async {
          final device = await _probe(client, host);
          if (device != null) found[device.dedupeKey] = device;
        }),
      );
    }
  }

  Future<DiscoveredDevice?> _probe(HttpClient client, String host) async {
    const timeout = Duration(milliseconds: 600);
    try {
      final request = await client.get(host, port, '/health').timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final json = jsonDecode(body);
      if (json is! Map || json['ok'] != true) return null;
      final hubId = json['hubId'] as String? ?? '';
      // 没有 hubId 的 200 不是 bridge(可能是别的 HTTP 服务)。
      if (hubId.isEmpty) return null;
      final cwd = json['cwd'] as String? ?? '';
      final rawName = json['name'];
      final configuredName = rawName is String ? rawName.trim() : '';
      final device = DiscoveredDevice(
        hubId: hubId,
        // 新版 /health 返回 P2P 配置中的设备名;旧版回退 cwd 末段。
        name: configuredName.isNotEmpty
            ? configuredName
            : cwd.isNotEmpty
            ? cwd.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last
            : host,
        host: host,
        port: port,
      );
      return device;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> rescan() async {
    // 立即补一轮(_scanOnce 有 _scanning 守卫,与周期轮不叠加)。
    if (_stopped) return;
    await _scanOnce();
  }

  @override
  Future<void> stop() async {
    _started = false;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}

bool _isWifiInterface(String name) {
  final normalized = name.toLowerCase();
  return normalized.startsWith('wlan') ||
      normalized.startsWith('wl') ||
      normalized == 'en0' ||
      normalized == 'en1' ||
      normalized.contains('wi-fi') ||
      normalized.contains('wifi');
}
