import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../theme/semantic_colors.dart';

String relativeTime(DateTime? t) {
  if (t == null) return '未知时间';
  final diff = DateTime.now().difference(t);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final mm = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '${t.year}-$mm-$dd';
}

/// 会话树**页面**(不再是弹窗)。
///
/// 之前它开在会话弹窗之上、再弹确认对话框 —— 三层模态叠加,而弹窗头部
/// 连返回控件都没有。提升为独立路由之后有真正的返回栈。
class SessionTreeScreen extends ConsumerStatefulWidget {
  const SessionTreeScreen({super.key});

  @override
  ConsumerState<SessionTreeScreen> createState() => _SessionTreeScreenState();
}

class _SessionTreeScreenState extends ConsumerState<SessionTreeScreen> {
  late Future<SessionTree?> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(piSessionProvider.notifier).getTree();
  }

  void _reload() {
    setState(() {
      _future = ref.read(piSessionProvider.notifier).getTree();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话树'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<SessionTree?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final tree = snapshot.data;
          if (tree == null || tree.roots.isEmpty) {
            return Center(
              child: Text('会话树不可用', style: theme.textTheme.bodyLarge),
            );
          }
          final path = tree.currentPath;
          final rows = <_TreeRow>[];
          void flatten(SessionTreeNode node, int depth) {
            rows.add(_TreeRow(node, depth));
            for (final child in node.children) {
              flatten(child, depth + (node.children.length > 1 ? 1 : 0));
            }
          }

          for (final root in tree.roots) {
            flatten(root, 0);
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.fork_right, size: 18),
                      label: Text('${tree.forkPoints.length} 个分叉点'),
                    ),
                    if (tree.isSummary)
                      const Chip(
                        avatar: Icon(Icons.desktop_windows_outlined, size: 18),
                        label: Text('桌面摘要'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => _TreeNodeTile(
                    row: rows[index],
                    onCurrentPath: path.contains(rows[index].node.id),
                    isLeaf: rows[index].node.id == tree.leafId,
                    onChanged: _reload,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TreeRow {
  const _TreeRow(this.node, this.depth);
  final SessionTreeNode node;
  final int depth;
}

class _TreeNodeTile extends ConsumerWidget {
  const _TreeNodeTile({
    required this.row,
    required this.onCurrentPath,
    required this.isLeaf,
    required this.onChanged,
  });

  final _TreeRow row;
  final bool onCurrentPath;
  final bool isLeaf;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final node = row.node;
    // 任何节点都能跳过去 —— 这就是"分支间自由切换"。
    // fork(另开一个会话文件)降为长按里的次要动作。
    final canNavigate = node.type == 'message' || node.type == 'branch_summary';
    final isHeadless = ref.watch(
      piSessionProvider.select((s) => s.selectedSource?.isHeadless == true),
    );

    final (icon, iconColor) = switch (node.type) {
      'message' when node.role == 'user' => (
        Icons.person_outline,
        onCurrentPath ? colors.primary : colors.onSurfaceVariant,
      ),
      'message' => (
        Icons.smart_toy_outlined,
        onCurrentPath ? colors.primary : colors.onSurfaceVariant,
      ),
      'compaction' => (Icons.compress, piColors.warning),
      'branch_summary' => (Icons.fork_right, colors.tertiary),
      _ => (Icons.circle_outlined, colors.onSurfaceVariant),
    };

    final indent = 16.0 + math.min(row.depth, 10) * 18;
    final tile = InkWell(
      onTap: canNavigate && !onCurrentPath
          ? () => _confirmNavigate(context, ref, node)
          : null,
      onLongPress: canNavigate && isHeadless
          ? () => _confirmFork(context, ref, node)
          : null,
      child: Padding(
        padding: EdgeInsets.only(
          // 缩进必须封顶:分叉树的 depth 没有上界,线性增长的 padding
          // 会把负约束喂给 Padding,窄屏上直接 assert 崩溃
          left: indent,
          right: 12,
          top: 5,
          bottom: 5,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 与首行文本垂直居中对齐,而不是随多行文本贴顶
            SizedBox(
              height: 20,
              child: Center(child: Icon(icon, size: 16, color: iconColor)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.preview.isEmpty ? node.type : node.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: onCurrentPath
                          ? colors.onSurface
                          : colors.onSurfaceVariant,
                      fontWeight: isLeaf ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  Row(
                    children: [
                      if (node.label != null) ...[
                        Icon(
                          Icons.bookmark_outline,
                          size: 12,
                          color: colors.tertiary,
                        ),
                        // 书签标签是用户自己起的,长度不可控
                        Flexible(
                          child: Text(
                            '${node.label} · ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.tertiary),
                          ),
                        ),
                      ],
                      if (node.time != null)
                        Text(
                          relativeTime(node.time),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      if (isLeaf)
                        Text(
                          ' · 当前位置',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.primary),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (node.children.length > 1)
              SizedBox(
                height: 20,
                child: Center(
                  child: Icon(
                    Icons.fork_right,
                    size: 14,
                    color: colors.tertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (node.collapsedBefore <= 0) return tile;
    // 桌面端剪掉了这段线性历史(见 relay.ts buildTreeSummary)。这里只标数量,
    // 不给可点的占位 —— 被折叠的节点没有传过来 id,点了没法回退到正确位置。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: indent, right: 12, top: 4, bottom: 4),
          child: Row(
            children: [
              SizedBox(
                height: 20,
                child: Center(
                  child: Icon(
                    Icons.more_vert,
                    size: 14,
                    color: colors.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '省略 ${node.collapsedBefore} 条',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        tile,
      ],
    );
  }

  /// 跳到会话树上的这个节点(原地回退,两端同步)。
  Future<void> _confirmNavigate(
    BuildContext context,
    WidgetRef ref,
    SessionTreeNode node,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('回到这里重新开始?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(node.preview, maxLines: 4, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            Text(
              '这之后的内容会从当前分支移开(不会被删掉,随时可以再切回来)。'
              '两端会同步到同一个分支。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('回到这里'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    // pop 之前抓齐:messenger 是 app 级永生,notifier 同理。
    // pop 之后再对路由里的 context 做任何 ancestor 查找都是踩框架时序。
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(piSessionProvider.notifier);
    final ok = await notifier.navigateTo(node.id);
    if (!context.mounted) return;
    // 回退成功就退回对话页看结果;失败留在树上让用户重试
    if (ok) Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? '已回到该节点' : '回退失败'),
        action: ok
            ? null
            : SnackBarAction(
                label: '重试',
                onPressed: () => unawaited(notifier.navigateTo(node.id)),
              ),
      ),
    );
    if (!ok) onChanged();
  }

  Future<void> _confirmFork(
    BuildContext context,
    WidgetRef ref,
    SessionTreeNode node,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从此节点另开一个会话?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(node.preview, maxLines: 4, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            Text(
              '会新建一个会话文件,当前会话保持原样。'
              '只想回到这里的话,直接点这个节点。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('另开会话'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(piSessionProvider.notifier).forkFrom(node.id);
    if (!context.mounted) return;
    if (ok) Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text(ok ? '已另开一个会话' : '操作失败或被取消')),
    );
  }
}
