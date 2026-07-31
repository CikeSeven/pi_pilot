import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_models.dart';
import '../core/lan_discovery.dart';
import '../core/settings_repository.dart';
import 'pi_session.dart';

/// 多设备管理:roster(已添加设备)+ 局域网发现 + 当前激活设备 +
/// **N 台设备同时保活连接**。
///
/// 保活的实现(迭代 2,见 docs/multi-device-plan.md §1.1):
/// family provider 的实例没人 watch 就会被销毁,连接随之断开。
/// 所以 [DeviceManagerNotifier.build] 里对 roster 每台设备
/// `ref.watch(piSessionFamilyProvider(id))`——只要 DeviceManager 活着
/// (它活着,因为 UI 常驻消费),每台设备的 [PiSessionNotifier] 就活着,
/// 各自的断线重连(_scheduleReconnect)也各跑各的。
///
/// roster 的 id 列表单独放一个轻量 provider([_rosterIdsProvider]),
/// 是因为 build() 不能 watch 自己的 state——ids 是保活的「schema」,
/// DeviceManagerState.devices 是完整数据,两者由本 notifier 同步更新。
class DeviceManagerState {
  const DeviceManagerState({
    this.devices = const [],
    this.discovered = const [],
    this.activeDeviceId,
    this.loaded = false,
  });

  /// 已添加设备(持久化于 `devices.list`)。
  final List<DeviceProfile> devices;

  /// 局域网发现到、尚未添加的设备。
  /// 迭代 3 接入 LanDiscovery(mDNS/子网扫描)前恒为空,UI 据此隐藏发现区。
  final List<DiscoveredDevice> discovered;

  /// 当前激活设备 id;聊天页读这台。null = 尚未选择(roster 为空)。
  final String? activeDeviceId;

  /// 首次磁盘加载是否完成(避免 hydrate 前闪空态)。
  final bool loaded;

  DeviceManagerState copyWith({
    List<DeviceProfile>? devices,
    List<DiscoveredDevice>? discovered,
    String? activeDeviceId,
    bool? loaded,
  }) {
    return DeviceManagerState(
      devices: devices ?? this.devices,
      discovered: discovered ?? this.discovered,
      activeDeviceId: activeDeviceId ?? this.activeDeviceId,
      loaded: loaded ?? this.loaded,
    );
  }
}

final deviceManagerProvider =
    NotifierProvider<DeviceManagerNotifier, DeviceManagerState>(
      DeviceManagerNotifier.new,
    );

/// roster 的设备 id 列表。DeviceManager 在 build() 里 watch 它做保活
/// (build 不能 watch 自己的 state,所以 ids 单独成 provider)。
final _rosterIdsProvider = NotifierProvider<_RosterIdsNotifier, List<String>>(
  _RosterIdsNotifier.new,
);

class _RosterIdsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void setIds(List<String> ids) => state = ids;
}

/// **当前设备的会话状态代理**。命名刻意保留旧的 `piSessionProvider`:
/// 聊天/会话/设置等几十个消费点读的都是「当前这台设备的 PiState」,
/// 语义不变、调用点零改动;切换激活设备时它自动改指另一台。
///
/// 需要按设备 id 精确取状态(设备列表页)时才用 piSessionFamilyProvider。
final piSessionProvider = Provider<PiState>((ref) {
  final activeId = ref.watch(
    deviceManagerProvider.select((s) => s.activeDeviceId),
  );
  if (activeId == null) return PiState.initial();
  return ref.watch(piSessionFamilyProvider(activeId));
});

/// **当前设备的 notifier 代理**。旧的 `piSessionNotifierProvider` 调用点
/// 换成 `ref.read(piSessionNotifierProvider)?.method()`——无激活设备时
/// 为 null,调用即静默落空(没有设备本来也发不出任何帧)。
final piSessionNotifierProvider = Provider<PiSessionNotifier?>((ref) {
  final activeId = ref.watch(
    deviceManagerProvider.select((s) => s.activeDeviceId),
  );
  if (activeId == null) return null;
  return ref.read(piSessionFamilyProvider(activeId).notifier);
});

/// 在线(connected)设备数,设备页页头用。
final onlineDeviceCountProvider = Provider<int>((ref) {
  final devices = ref.watch(deviceManagerProvider.select((s) => s.devices));
  var count = 0;
  for (final device in devices) {
    final status = ref.watch(
      piSessionFamilyProvider(device.id).select((s) => s.status),
    );
    if (status == PiConnStatus.connected) count++;
  }
  return count;
});

class DeviceManagerNotifier extends Notifier<DeviceManagerState> {
  final SettingsRepository _repo = SettingsRepository();

  /// 本批次 hydrate 已发起过连接的设备,防止 roster 反复刷新时重复 connect。
  final Set<String> _connectRequested = {};

  @override
  DeviceManagerState build() {
    // 保活:watch 每台设备的 family 实例(status/hubId 粒度,不追流式细节)。
    for (final id in ref.watch(_rosterIdsProvider)) {
      ref.watch(piSessionFamilyProvider(id).select((s) => s.status));
      // hubId 写回:握手成功后把 bridge 身份记进 roster,
      // DHCP 换 IP 时靠它认出「这还是原来那台」。
      final hubId = ref.watch(
        piSessionFamilyProvider(id).select((s) => s.hubId),
      );
      if (hubId != null && hubId.isNotEmpty) {
        unawaited(_persistHubId(id, hubId));
      }
    }
    unawaited(_hydrate());
    // 局域网发现:mDNS 为主、子网扫描兜底。测试环境跳过——
    // 扫描/组播都是真实网络行为,理由同 _hydrate 的连接守卫。
    if (!isTestEnvironment) {
      final discovery = LanDiscovery.platform();
      final sub = discovery.devices.listen(_onDiscovered);
      unawaited(discovery.start());
      ref.onDispose(() {
        unawaited(sub.cancel());
        unawaited(discovery.stop());
      });
    }
    return const DeviceManagerState();
  }

  /// 发现流入口:更新 discovered,并对 roster 设备做 DHCP 自愈。
  void _onDiscovered(List<DiscoveredDevice> list) {
    state = state.copyWith(discovered: list);
    for (final discovered in list) {
      if (discovered.hubId.isEmpty) continue;
      final hit = state.devices
          .where((device) => device.lastHubId == discovered.hubId)
          .firstOrNull;
      // hubId 认出「这还是原来那台」,但地址变了 → 静默更新并重连。
      if (hit != null &&
          (hit.host != discovered.host || hit.port != discovered.port)) {
        unawaited(refreshAddress(discovered));
      }
    }
  }

  Future<void> _persistHubId(String deviceId, String hubId) async {
    final device = state.devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null || device.lastHubId == hubId) return;
    await upsertDevice(device.copyWith(lastHubId: hubId), connect: false);
  }

  Future<void> _hydrate() async {
    final devices = await _repo.loadDevices();
    var activeId = await _repo.loadActiveDeviceId();
    // 持久化的激活 id 可能已随设备删除失效,落到第一台。
    if (activeId == null || !devices.any((d) => d.id == activeId)) {
      activeId = devices.isEmpty ? null : devices.first.id;
    }
    ref.read(_rosterIdsProvider.notifier).setIds([
      for (final d in devices) d.id,
    ]);
    state = state.copyWith(
      devices: devices,
      activeDeviceId: activeId,
      loaded: true,
    );
    // 启动即并发连接所有设备——「多连接保活」的入口。
    // flutter test 环境下绝不发起真实连接:否则 widget 测试会向假地址
    // 打 WebSocket,重连退避的 timer 让 pumpAndSettle 永远等不到稳定,
    // 测试进程空转烧 CPU。
    if (isTestEnvironment) return;
    for (final device in devices) {
      unawaited(connectDevice(device));
    }
  }

  /// 是否处于 flutter test 运行环境。
  static bool get isTestEnvironment =>
      Platform.environment.containsKey('FLUTTER_TEST');

  /// 连接当前激活设备(聊天页空态的「连接」按钮用)。
  Future<void> connectActiveDevice() async {
    final active = state.devices
        .where((d) => d.id == state.activeDeviceId)
        .firstOrNull;
    if (active == null) return;
    await connectDevice(active);
  }

  /// 连接一台设备(幂等):已在连/已连上的不重复发起;配置不全的跳过。
  Future<void> connectDevice(DeviceProfile device) async {
    final session = ref.read(piSessionFamilyProvider(device.id));
    if (session.hasSession ||
        session.status == PiConnStatus.connecting ||
        _connectRequested.contains(device.id)) {
      return;
    }
    _connectRequested.add(device.id);
    try {
      await ref.read(piSessionFamilyProvider(device.id).notifier).connect(
        device,
      );
    } finally {
      // 失败后允许下次(编辑保存/下拉刷新)再发起。
      _connectRequested.remove(device.id);
    }
  }

  /// 新增或覆盖一台设备。默认保存后立即连接并成为激活设备
  /// (用户刚加完就想看它);hubId 写回等内部更新传 connect: false。
  Future<void> upsertDevice(DeviceProfile device, {bool connect = true}) async {
    await _repo.upsertDevice(device);
    final devices = await _repo.loadDevices();
    ref.read(_rosterIdsProvider.notifier).setIds([
      for (final d in devices) d.id,
    ]);
    state = state.copyWith(devices: devices, activeDeviceId: device.id);
    await _repo.saveActiveDeviceId(device.id);
    if (connect) {
      // 配置变了要重连才生效:先断开旧快照再按新配置连。
      ref.read(piSessionFamilyProvider(device.id).notifier).disconnect();
      unawaited(connectDevice(device));
    }
  }

  Future<void> removeDevice(String deviceId) async {
    // 先断连再移除:family 实例失去保活 watch 后会被销毁,
    // 但显式 disconnect 能保证通道立即关闭,不等 GC。
    ref.read(piSessionFamilyProvider(deviceId).notifier).disconnect();
    await _repo.removeDevice(deviceId);
    final devices = await _repo.loadDevices();
    ref.read(_rosterIdsProvider.notifier).setIds([
      for (final d in devices) d.id,
    ]);
    final activeId = devices.isEmpty
        ? null
        : (state.activeDeviceId == deviceId
              ? devices.first.id
              : state.activeDeviceId);
    state = state.copyWith(devices: devices, activeDeviceId: activeId);
  }

  /// 切换聊天页指向的设备。连接早已保活,切换是即时的。
  Future<void> setActive(String deviceId) async {
    if (!state.devices.any((d) => d.id == deviceId)) return;
    state = state.copyWith(activeDeviceId: deviceId);
    await _repo.saveActiveDeviceId(deviceId);
  }

  /// DHCP 自愈:发现流里 hubId 命中但地址变了 → 更新 roster 并重连。
  Future<void> refreshAddress(DiscoveredDevice discovered) async {
    final updated = await _repo.refreshDeviceAddress(
      hubId: discovered.hubId,
      host: discovered.host,
      port: discovered.port,
    );
    if (updated == null) return;
    state = state.copyWith(
      devices: [
        for (final d in state.devices) d.id == updated.id ? updated : d,
      ],
    );
    // 地址变了,旧连接的 host 快照已失效,按新地址重连。
    ref.read(piSessionFamilyProvider(updated.id).notifier).disconnect();
    unawaited(connectDevice(updated));
  }
}
