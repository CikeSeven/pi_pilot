import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../sessions/session_tree_screen.dart';
import '../../theme/paper.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'session_sheet.dart';

/// 对话页顶栏:**PiPilot 衬线字标 + 编辑式状态副行**。
///
/// Editorial Retro 改版。旧版顶栏是一整块 `primaryContainer` 实色,
/// 那是「顶栏大色块」的现代 App 语言;新设计里顶栏与内容**同一张纸**,
/// 靠衬线字标和一条细线分隔——像刊物的报头。
///
/// 结构:
/// ```
/// ✦ PiPilot                    [中断] [⋯]
///   ● pi_pilot · glm-5.2 · ctx 32%
/// ─────────────────────────────────────  ← 细线
/// ```
/// 字标用衬线(气质位),状态副行用无衬线小字(信息位)——
/// 这是「衬线负责文艺,无衬线负责效率」在顶栏的落点。
class ChatAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const ChatAppBar({super.key});

  static const _height = 76.0;

  @override
  Size get preferredSize => const Size.fromHeight(_height + 1);

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
      // 顶栏就是纸本身 —— 与内容同底,靠字标和底部细线分隔。
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleSpacing: 4,
      // 底部细线:编辑式版头的分隔语言,替代滚动阴影。
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: EditorialRule(color: colors.outlineVariant),
      ),
      title: InkWell(
        borderRadius: BorderRadius.circular(PiShape.sm),
        onTap: () {
          HapticFeedback.selectionClick();
          showSessionSheet(context, ref);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 报头行:星芒 + 衬线字标 + 会话名 + 展开箭头
              Row(
                children: [
                  Icon(Icons.auto_awesome, size: 14, color: colors.primary),
                  const SizedBox(width: 7),
                  Text(
                    'PiPilot',
                    style: AppType.wordmark(size: 20, color: colors.onSurface),
                  ),
                  const SizedBox(width: 10),
                  // 会话名跟在字标后,用无衬线中号 —— 它是信息不是气质
                  Flexible(
                    child: Text(
                      _title(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.expand_more,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              // 状态副行:圆点 + 目录 · 模型 · 上下文
              Row(
                children: [
                  StatusDot(status: state.status),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _subtitle(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
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
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
