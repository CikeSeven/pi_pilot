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
import 'device_sessions_page.dart' show windowTitleFor;

/// 聊天页左滑抽屉:**所有设备上正开着的窗口**,按设备分组。
///
/// 旧抽屉是设备列表的第二个入口;底栏有了「设备」tab 之后那个入口
/// 就失去意义。抽屉的新职责是**快速切换窗口**:每台设备上开着的
/// pi 窗口按设备分组列出,点一下切过去(切设备 + 选源一步完成)。
///
/// 只列「正开着的窗口」(desktop 且 connected 的 source):
/// - 磁盘上的休眠会话不属于这里,它们在设备的会话列表页里;
/// - 没有窗口的设备整组隐藏,不留空标题。
class SessionsDrawer extends StatelessWidget {
  const SessionsDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    // 与旧抽屉同一副骨架:右上「开口的纸角」圆角,右下必须直角
    // 贴住屏幕底,否则底下透出主页会有「悬空」的错觉。
    return const Drawer(
      child: ClipRRect(
        borderRadius: BorderRadius.only(topRight: Radius.circular(PiShape.lg)),
        child: BackdropPaper(child: _DrawerBody()),
      ),
    );
  }
}

/// 一台设备 + 它正开着的窗口。
class _WindowGroup {
  const _WindowGroup({
    required this.device,
    required this.state,
    required this.windows,
  });

  final DeviceProfile device;
  final PiState state;
  final List<SourceInfo> windows;
}

class _DrawerBody extends ConsumerWidget {
  const _DrawerBody();

  void _openWindow(
    BuildContext context,
    WidgetRef ref,
    _WindowGroup group,
    SourceInfo source,
  ) {
    final isCurrentDevice =
        group.device.id == ref.read(deviceManagerProvider).activeDeviceId;
    final isCurrentWindow =
        isCurrentDevice && source.id == group.state.selectedSourceId;

    // 先关抽屉:切设备/选源都在后台完成,不让用户等。
    Navigator.of(context).pop();
    if (isCurrentWindow) return;
    if (!isCurrentDevice) {
      unawaited(
        ref.read(deviceManagerProvider.notifier).setActive(group.device.id),
      );
    }
    unawaited(
      ref
          .read(piSessionFamilyProvider(group.device.id).notifier)
          .selectSource(source.id),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(deviceManagerProvider);
    final activeId = manager.activeDeviceId;

    // 逐台设备读它自己的 family 实例(多连接保活后每台都是真实连接),
    // 只收「正开着的窗口」,没有窗口的设备整组不进列表。
    final groups = <_WindowGroup>[];
    for (final device in manager.devices) {
      final state = ref.watch(piSessionFamilyProvider(device.id));
      final windows = [
        for (final source in state.sources)
          if (source.isDesktop && source.connected) source,
      ];
      if (windows.isNotEmpty) {
        groups.add(
          _WindowGroup(device: device, state: state, windows: windows),
        );
      }
    }
    final total = groups.fold<int>(
      0,
      (sum, group) => sum + group.windows.length,
    );

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DrawerHeader(total: total),
          Expanded(
            child: groups.isEmpty
                ? _Empty(hasDevices: manager.devices.isNotEmpty)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      for (final group in groups) ...[
                        _DeviceRule(name: group.device.name),
                        const SizedBox(height: 10),
                        for (final source in group.windows) ...[
                          _WindowTile(
                            source: source,
                            streaming: group.state.sessions
                                .where((item) => item.sourceId == source.id)
                                .any((item) => item.streaming),
                            isCurrent:
                                group.device.id == activeId &&
                                source.id == group.state.selectedSourceId,
                            onTap: () =>
                                _openWindow(context, ref, group, source),
                          ),
                          const SizedBox(height: 8),
                        ],
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 页头:「会话」衬线大标题 + 一行斜体副标。
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '会话',
            style: AppType.displayTitle(size: 26, color: colors.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            total > 0 ? '$total 个窗口正开着,点一下就切过去' : '每台设备上开着的窗口,都在这里',
            style: AppType.serifItalic(
              size: 13.5,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设备分隔线:**左短右长,中间是设备名**。
///
/// 版式借自杂志的栏目标记——不对称才显得「设计过的」:
/// 左侧一段短短的实线领出设备名(衬线斜体),右侧一条更细更淡的线
/// 一直延伸到抽屉边缘,把这一组窗口「收」在设备名下。
class _DeviceRule extends StatelessWidget {
  const _DeviceRule({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        // 左:短线,略粗并带主题色,像栏目标记的引导线。
        SizedBox(
          width: 22,
          child: EditorialRule(
            color: colors.primary,
            opacity: 0.6,
            height: 1.5,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.serifItalic(size: 14, color: colors.onSurface),
          ),
        ),
        const SizedBox(width: 12),
        // 右:细线淡线,一路伸到抽屉边缘。
        Expanded(
          child: EditorialRule(color: colors.onSurfaceVariant, opacity: 0.3),
        ),
      ],
    );
  }
}

/// 窗口行:当前选中的用陶土橙实心,其余抬升面 + 描边。
/// 比设备页那张窗口卡紧凑一档——抽屉是快速切换器,不是陈列页。
class _WindowTile extends StatelessWidget {
  const _WindowTile({
    required this.source,
    required this.streaming,
    required this.isCurrent,
    required this.onTap,
  });

  final SourceInfo source;
  final bool streaming;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bg = isCurrent ? colors.primary : colors.surfaceContainerLow;
    final fg = isCurrent ? colors.onPrimary : colors.onSurface;
    final fgMuted = isCurrent
        ? colors.onPrimary.withValues(alpha: 0.78)
        : colors.onSurfaceVariant;

    return Material(
      color: bg,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        side: BorderSide(
          color: isCurrent ? Colors.transparent : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(PiShape.sm),
                  border: Border.all(color: fg.withValues(alpha: 0.22)),
                ),
                child: Icon(
                  Icons.desktop_windows_outlined,
                  size: 18,
                  color: fg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      windowTitleFor(
                        cwd: source.cwd,
                        sessionName: source.sessionName,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      streaming ? '正在生成…' : (source.cwd ?? source.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoLabel(color: fgMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (streaming)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              else if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(PiShape.sm),
                  ),
                  child: Text('当前', style: AppType.eyebrow(color: fg)),
                )
              else
                Icon(Icons.chevron_right, size: 18, color: fgMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态:插画 + 衬线标题 + 说明。roster 为空与「有设备但没开窗口」
/// 是两种引导,文案分开。
class _Empty extends StatelessWidget {
  const _Empty({required this.hasDevices});

  final bool hasDevices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EditorialOrnament(size: 120),
              const SizedBox(height: 20),
              Text(
                hasDevices ? '没有打开的窗口' : '还没有设备',
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 21, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                hasDevices
                    ? '在电脑上开一个 pi 窗口,\n它会自动出现在这里。'
                    : '先到底部的「设备」页\n添加你的第一台电脑。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
