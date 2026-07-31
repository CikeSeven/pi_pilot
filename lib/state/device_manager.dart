import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_models.dart';
import '../core/settings_repository.dart';

/// 多设备管理:roster(已添加设备)+ 局域网发现 + 当前激活设备。
///
/// **本文件是迭代 1 的占位骨架**(见 docs/multi-device-plan.md §7):
/// 只负责 roster 的加载/增删改/激活设备选择,以及发现列表的容器。
/// 真正的「N 台设备同时保活连接」要等 `pi_session.dart` family 化(迭代 2)
/// 之后在这里对 roster 每台设备 `ref.watch(piSessionProvider(device.id))`。
///
/// 因此本迭代里设备卡的在线状态仍从旧版单连接 `piSessionProvider` 旁路推导
/// (host/port/token 匹配的那台 = 当前连接),见 devices_page.dart。
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

  /// 首次磁盘加载是否完成(避免hydrate 前闪空态)。
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

class DeviceManagerNotifier extends Notifier<DeviceManagerState> {
  final SettingsRepository _repo = SettingsRepository();

  @override
  DeviceManagerState build() {
    unawaited(_hydrate());
    return const DeviceManagerState();
  }

  Future<void> _hydrate() async {
    final devices = await _repo.loadDevices();
    var activeId = await _repo.loadActiveDeviceId();
    // 持久化的激活 id 可能已随设备删除失效,落到第一台。
    if (activeId == null || !devices.any((d) => d.id == activeId)) {
      activeId = devices.isEmpty ? null : devices.first.id;
    }
    state = state.copyWith(
      devices: devices,
      activeDeviceId: activeId,
      loaded: true,
    );
  }

  /// 新增或覆盖一台设备。新设备自动成为激活设备(用户刚加完就想看它)。
  Future<void> upsertDevice(DeviceProfile device) async {
    await _repo.upsertDevice(device);
    final devices = await _repo.loadDevices();
    state = state.copyWith(devices: devices, activeDeviceId: device.id);
    await _repo.saveActiveDeviceId(device.id);
  }

  Future<void> removeDevice(String deviceId) async {
    await _repo.removeDevice(deviceId);
    final devices = await _repo.loadDevices();
    final activeId = devices.isEmpty
        ? null
        : (state.activeDeviceId == deviceId
              ? devices.first.id
              : state.activeDeviceId);
    state = state.copyWith(devices: devices, activeDeviceId: activeId);
  }

  /// 切换聊天页指向的设备。连接早已保活,切换是即时的(迭代 2 之后)。
  Future<void> setActive(String deviceId) async {
    if (!state.devices.any((d) => d.id == deviceId)) return;
    state = state.copyWith(activeDeviceId: deviceId);
    await _repo.saveActiveDeviceId(deviceId);
  }

  /// DHCP 自愈:发现流里 hubId 命中但地址变了 → 更新 roster 并触发重连
  /// (重连在迭代 2 接入,这里先把地址修正落盘)。
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
  }
}
