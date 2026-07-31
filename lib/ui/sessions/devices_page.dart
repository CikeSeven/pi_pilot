import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_models.dart';
import '../../state/device_manager.dart';
import '../../state/pi_session.dart';
import '../theme/paper.dart';
import '../theme/shapes.dart';
import '../theme/squircle.dart';
import '../theme/typography.dart';
import '../shell/liquid_nav_bar.dart' show kLiquidNavBarHeight;
import 'device_edit_sheet.dart';
import 'device_sessions_page.dart';

/// 设备页:**深炭全屏 + 复古插画 + 陶土橙当前卡**(Editorial Retro)。
///
/// 多设备改造(见 docs/multi-device-plan.md)后这一页是**两级结构的第一级**:
/// - 第一级(本文件)= 设备列表:已添加设备 + 局域网发现 + 手动添加入口;
/// - 第二级([DeviceSessionsPage])= 某台设备的会话列表(旧版设备页的正身,
///   pi 窗口 + 历史会话两段原样下沉)。
///
/// 设备页曾兼任会话页的左滑抽屉;底栏有了「设备」tab、抽屉改为
/// 会话列表([SessionsDrawer])之后,这一页只剩底栏一个入口。
///
/// 数据源:roster/激活设备来自 [deviceManagerProvider];每台设备的在线
/// 状态/窗口数/流式标记来自它自己的 `piSessionFamilyProvider(device.id)`
/// ——多连接保活(迭代 2)后,这里看到的每台设备都是真实连接。
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 背景明暗**跟随主题**。旧版这里写死 `dark: true`,于是浅色模式下
    // 别的页面是奶油纸、这一页却是深炭黑,切过去像换了个 app ——
    // 那就是「撕裂感」的真正来源。
    // 两用页面:既作底栏「设备」tab,也作 push 路由。
    // 自带 BackdropPaper 保证两种场景背景都正确(详见 SettingsScreen 注释)。
    return const Scaffold(body: BackdropPaper(child: _DevicesBody()));
  }
}

class _DevicesBody extends ConsumerStatefulWidget {
  const _DevicesBody();

  @override
  ConsumerState<_DevicesBody> createState() => _DevicesBodyState();
}

class _DevicesBodyState extends ConsumerState<_DevicesBody> {
  /// 打开添加/编辑 sheet 并落库。保存后**留在列表页**:连接结果直接
  /// 显示在设备卡上,连上了用户自己点进去——不再未经成功就跳转。
  Future<void> _editDevice({
    DeviceProfile? existing,
    DiscoveredDevice? discovered,
  }) async {
    final result = await showDeviceEditSheet(
      context,
      existing: existing,
      discovered: discovered,
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(deviceManagerProvider.notifier);
    final device = result.device;
    try {
      if (result.deleted) {
        if (existing != null) {
          await notifier.removeDevice(existing.id);
          if (mounted) {
            messenger.showSnackBar(const SnackBar(content: Text('设备已删除')));
          }
        }
        return;
      }
      if (device == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 30),
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('正在保存并连接 ${device.name}…')),
            ],
          ),
        ),
      );
      await notifier.upsertDevice(device);
      if (!mounted) return;
      final saved = ref
          .read(deviceManagerProvider)
          .devices
          .any((item) => item.id == device.id);
      if (!saved) {
        throw StateError('保存完成后设备列表未更新');
      }
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(_isEdit(existing) ? '设备已保存，正在重新连接' : '设备已保存，正在连接'),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Device save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('保存设备失败：${_deviceSaveError(error)}')),
      );
    }
  }

  String _deviceSaveError(Object error) {
    final message = error.toString().replaceFirst(
      RegExp(r'^\w*(?:Error|Exception):\s*'),
      '',
    );
    return message.isEmpty ? '请重试' : message;
  }

  bool _isEdit(DeviceProfile? existing) => existing != null;

  void _openSessions(DeviceProfile device) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DeviceSessionsPage(device: device)),
    );
    // 点哪台,聊天页就指向哪台。
    ref.read(deviceManagerProvider.notifier).setActive(device.id);
  }

  /// 手动刷新:重扫局域网 + 刷新已连设备的窗口列表。
  /// RefreshIndicator 等待这个 Future,转动画直到收窗口(3 秒)。
  Future<void> _rescan() =>
      ref.read(deviceManagerProvider.notifier).rescanDiscovery();

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(deviceManagerProvider);
    final onlineCount = ref.watch(onlineDeviceCountProvider);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            onlineCount: onlineCount,
            total: manager.devices.length,
            onAdd: () => _editDevice(),
          ),
          Expanded(
            child: RefreshIndicator(onRefresh: _rescan, child: _body(manager)),
          ),
        ],
      ),
    );
  }

  Widget _body(DeviceManagerState manager) {
    final colors = Theme.of(context).colorScheme;

    // 发现区:已经在 roster 里(按 hubId 或地址命中)的不重复列。
    // 必须在空 roster 判断前计算:首次使用时 roster 本来就是空的,
    // 不能因此把已经发现的设备卡提前遮掉。
    final discovered = [
      for (final d in manager.discovered)
        if (!manager.devices.any(
          (p) =>
              (d.hubId.isNotEmpty && p.lastHubId == d.hubId) ||
              (p.host == d.host && p.port == d.port),
        ))
          d,
    ];

    if (manager.loaded &&
        manager.devices.isEmpty &&
        discovered.isEmpty &&
        !manager.isScanning) {
      return _EmptyRoster(onAdd: () => _editDevice());
    }

    return ListView(
      // 内容不足一屏时也要能下拉(下拉刷新是唯一全页刷新手势)。
      physics: const AlwaysScrollableScrollPhysics(),
      // 底栏在设备/设置页常驻(AppShell),列表底部让位栏高 + 安全区。
      // viewPadding 不被祖先 SafeArea 消费,拿到的是真实系统安全区。
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        MediaQuery.viewPaddingOf(context).bottom + kLiquidNavBarHeight + 16,
      ),
      children: [
        for (final device in manager.devices) ...[
          _RosterDeviceCard(
            device: device,
            isActive: device.id == manager.activeDeviceId,
            onOpen: () => _openSessions(device),
            onEdit: () => _editDevice(existing: device),
            onRetry: () => unawaited(
              ref.read(deviceManagerProvider.notifier).connectDevice(device),
            ),
          ),
          const SizedBox(height: 10),
        ],
        // 发现区:扫描中也显示这一节,让「正在扫」有地方落脚。
        // 右上角刷新按钮挪到这里 + 全页下拉刷新;扫描时图标变转圈。
        if (discovered.isNotEmpty || manager.isScanning) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: Eyebrow(
                    text: discovered.isEmpty
                        ? '局域网发现'
                        : '局域网发现 · ${discovered.length}',
                    color: colors.onSurfaceVariant,
                    withRule: true,
                  ),
                ),
                const SizedBox(width: 10),
                if (manager.isScanning)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  )
                else
                  InkResponse(
                    onTap: _rescan,
                    radius: 18,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.refresh,
                        size: 16,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (discovered.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                '正在扫描局域网…',
                style: AppType.monoLabel(color: colors.onSurfaceVariant),
              ),
            )
          else
            for (final d in discovered) ...[
              _DiscoveredCard(
                discovered: d,
                onTap: () => _editDevice(discovered: d),
              ),
              const SizedBox(height: 10),
            ],
        ],
        const SizedBox(height: 4),
        _AddDeviceCard(onTap: () => _editDevice()),
      ],
    );
  }
}

/// 页头:衬线大标题 + 说明 + 右上角添加设备按钮。
class _Header extends StatelessWidget {
  const _Header({
    required this.onlineCount,
    required this.total,
    required this.onAdd,
  });

  final int onlineCount;
  final int total;

  /// 右上角「添加设备」。旧版这个位置是刷新按钮,刷新已挪到
  /// 发现区小节头 + 全页下拉手势。
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '设备',
                style: AppType.displayTitle(size: 27, color: colors.onSurface),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Icon(
                  Icons.auto_awesome,
                  size: 15,
                  color: colors.primary,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                tooltip: '添加设备',
                color: colors.primary,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '每台电脑是一个工作台',
            style: AppType.serifItalic(
              size: 14,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Eyebrow(
            text: total == 0 ? '离线' : '在线 · $onlineCount/$total',
            color: colors.primary,
            withRule: true,
          ),
        ],
      ),
    );
  }
}

/// 已添加设备卡:**当前设备陶土橙实心**,其余深色抬升面 + 描边。
///
/// 连接结果直接长在卡片上:连接中转圈、失败显示原因并把右侧换成
/// 重试按钮、成功才出现 chevron/「当前」标。**只有在线能点进会话页**;
/// 未连接/失败/连接中点卡片弹出编辑弹窗改连接信息。
/// 状态来自这台设备自己的 family 实例。
class _RosterDeviceCard extends ConsumerWidget {
  const _RosterDeviceCard({
    required this.device,
    required this.isActive,
    required this.onOpen,
    required this.onEdit,
    required this.onRetry,
  });

  final DeviceProfile device;

  /// 聊天页指向的设备(activeDeviceId)。与「在线」是两个维度:
  /// 在线 ≠ 当前,当前设备掉线时也保持当前标。
  final bool isActive;

  /// 在线时点卡片:进入这台设备的会话页。
  final VoidCallback onOpen;

  /// 不在线时点卡片(或长按):弹编辑弹窗改连接信息。
  final VoidCallback onEdit;

  /// 右侧重试按钮(不在线且不处于连接中时显示)。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final conn = ref.watch(piSessionFamilyProvider(device.id));

    final online = conn.status == PiConnStatus.connected;
    final connecting = conn.status == PiConnStatus.connecting;
    final failed = conn.status == PiConnStatus.failed;
    final streaming = online && conn.sessions.any((item) => item.streaming);
    final windowCount = online
        ? conn.sources.where((s) => s.isDesktop && s.connected).length
        : 0;

    // 当前设备 = 陶土橙实心卡,是这一页的视觉主角(沿用旧版约定)。
    final bg = isActive ? colors.primary : colors.surfaceContainerLow;
    final fg = isActive ? colors.onPrimary : colors.onSurface;
    final fgMuted = isActive
        ? colors.onPrimary.withValues(alpha: 0.78)
        : colors.onSurfaceVariant;

    final routeLabel = conn.activeTransport?.label ?? device.transportLabel;

    // 副标:在线显示实际通道;重连时保留上一次通道标记;失败显示原因。
    final subtitle = switch ((online, connecting, streaming)) {
      (true, _, true) => '$routeLabel · 正在生成…',
      (true, _, false) => '$routeLabel · $windowCount 个窗口',
      (_, true, _) when conn.activeTransport != null => '$routeLabel · 重连中…',
      (_, true, _) => '连接中…',
      _ when failed && conn.activeTransport != null =>
        '$routeLabel · ${conn.error ?? '连接失败'}',
      _ when failed => conn.error ?? '连接失败,点按修改配置',
      _ => '${device.transportLabel} · 点按配置连接',
    };

    return Material(
      color: bg,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(
          color: isActive ? Colors.transparent : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 只有连接成功才进会话页;其余状态点卡片 = 改连接信息。
        onTap: online ? onOpen : onEdit,
        onLongPress: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
          child: Row(
            children: [
              // 设备图标:方正印章
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(PiShape.sm),
                  border: Border.all(color: fg.withValues(alpha: 0.22)),
                ),
                child: Icon(
                  Icons.computer,
                  size: 20,
                  color: online || isActive ? fg : fgMuted,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoLabel(
                        color: failed && !isActive ? colors.error : fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (connecting || streaming)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
                )
              else if (!online)
                // 离线/失败:右侧换成重试按钮,失败时用错误色强调。
                IconButton(
                  onPressed: onRetry,
                  tooltip: '重试连接',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.refresh,
                    size: 20,
                    color: isActive ? fg : (failed ? colors.error : fgMuted),
                  ),
                )
              else if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(PiShape.sm),
                  ),
                  child: Text('当前', style: AppType.eyebrow(color: fg)),
                )
              else
                Icon(Icons.chevron_right, size: 20, color: fgMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 局域网发现卡(未添加):比已添加设备卡**轻一档**——
/// 复刻历史卡对设备卡的轻量关系,因为它「还不是你的设备」。
/// 右端是 ＋ 而不是 chevron:动作是「添加」,不是「进入」。
class _DiscoveredCard extends StatelessWidget {
  const _DiscoveredCard({required this.discovered, required this.onTap});

  final DiscoveredDevice discovered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fgMuted = colors.onSurfaceVariant;

    return Material(
      color: colors.surfaceContainerLowest,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: fgMuted.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(PiShape.sm),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Icon(Icons.radar, size: 18, color: colors.primary),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      discovered.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${discovered.host}:${discovered.port} · 待添加',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoLabel(color: fgMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.add_circle_outline, size: 20, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 手动添加入口:最轻的一档卡,虚位以待的语义。
class _AddDeviceCard extends StatelessWidget {
  const _AddDeviceCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                '手动添加设备',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// roster 为空时的首装空态:插画 + 衬线标题 + 主行动。
class _EmptyRoster extends StatelessWidget {
  const _EmptyRoster({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        // 空态内容不足一屏,不给 AlwaysScrollable 就拉不动下拉刷新。
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EditorialOrnament(size: 132),
              const SizedBox(height: 22),
              Text(
                '还没有设备',
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 22, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                '在电脑上启动 bridge,\n同一局域网的设备会自动出现在这里。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('手动添加设备'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
