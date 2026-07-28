import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../sessions/session_tree_screen.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import 'session_sheet.dart';

/// 对话页顶栏。
///
/// 相比旧版:**删掉了 48dp 的等宽字体芯片行**(终端风最后的残留),高度
/// 104 → 72;背景改用 `primaryContainer` 实色块(用户要的「顶栏大色块」);
/// action 从最多 4 个图标收敛到 2 个,其余进溢出菜单。
class ChatAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const ChatAppBar({super.key});

  static const _height = 72.0;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  /// 副标题:目录 · 模型 · 上下文占用,一行讲完。
  /// 这三条信息以前各占一个等宽芯片,吃掉整整 48dp。
  String _subtitle(PiState state) {
    if (state.status != PiConnStatus.connected) {
      return switch (state.status) {
        PiConnStatus.connecting => '连接中…',
        PiConnStatus.failed => '连接失败',
        _ => '未连接',
      };
    }
    final dir = state.cwd?.split('/').where((p) => p.isNotEmpty).lastOrNull;
    final percent = state.contextUsage?.percent;
    return [
      ?dir,
      ?state.modelName,
      if (percent != null) 'ctx $percent%',
    ].join(' · ');
  }

  String _title(PiState state) {
    final name = state.sessionName;
    if (name != null && name.isNotEmpty) return name;
    return state.selectedSource?.label ?? 'PiPilot';
  }

  Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('断开连接?'),
        content: const Text('会话仍会保留在电脑上,下次连接可增量恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      ref.read(piSessionProvider.notifier).disconnect();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(piSessionProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final notifier = ref.read(piSessionProvider.notifier);
    final canUndo = !state.isStreaming && notifier.undoTargetEntryId != null;

    return AppBar(
      toolbarHeight: _height,
      // 「顶栏大色块」:整条顶栏是 primaryContainer 实色,不再是灰白底
      backgroundColor: colors.primaryContainer,
      foregroundColor: colors.onPrimaryContainer,
      surfaceTintColor: colors.surfaceTint,
      centerTitle: false,
      titleSpacing: 4,
      title: InkWell(
        borderRadius: BorderRadius.circular(PiShape.md),
        onTap: () {
          HapticFeedback.selectionClick();
          showSessionSheet(context, ref);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              StatusDot(status: state.status),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      _subtitle(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onPrimaryContainer.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.expand_more,
                size: 20,
                color: colors.onPrimaryContainer,
              ),
            ],
          ),
        ),
      ),
      actions: [
        // 任意一端、任意时刻都能打断
        if (state.isStreaming)
          IconButton(
            tooltip: '中断',
            icon: const Icon(Icons.stop_circle_outlined),
            color: colors.error,
            onPressed: () => unawaited(notifier.abort()),
          ),
        MenuAnchor(
          builder: (context, controller, _) => IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.undo_rounded),
              onPressed: canUndo
                  ? () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final ok = await notifier.undoLastTurn();
                      messenger.showSnackBar(
                        SnackBar(content: Text(ok ? '已撤销上一轮' : '撤销失败')),
                      );
                    }
                  : null,
              child: const Text('撤销上一轮'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.account_tree_outlined),
              onPressed: state.hasSelectedSource
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SessionTreeScreen(),
                      ),
                    )
                  : null,
              child: const Text('会话树'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.link_off),
              onPressed: state.hasSession
                  ? () => unawaited(_confirmDisconnect(context, ref))
                  : null,
              child: const Text('断开连接'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 连接状态圆点;连接中带呼吸脉冲。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.status});

  final PiConnStatus status;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    if (widget.status == PiConnStatus.connecting) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final color = switch (widget.status) {
      PiConnStatus.connected => piColors.success,
      PiConnStatus.connecting => piColors.warning,
      PiConnStatus.failed => colors.error,
      PiConnStatus.disconnected => colors.outline,
    };
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(_pulse),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
