import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../theme/semantic_colors.dart';

/// 设置页各子页共用的卡片控件。
///
/// 原来它们都是 `settings_screen.dart` 里的私有类,和 832 行的单页挤在一起;
/// 拆成子页之后需要跨文件复用,所以提到这里并公开。
class HubSourceCard extends ConsumerWidget {
  const HubSourceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piState = ref.watch(piSessionProvider);
    final source = piState.selectedSource;
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              source?.isDesktop == true
                  ? Icons.desktop_windows_outlined
                  : Icons.dns_outlined,
              color: source?.connected == true
                  ? colors.primary
                  : colors.outline,
            ),
            title: Text(source?.label ?? '未选择 source'),
            subtitle: Text(
              source == null
                  ? '${piState.sources.where((item) => item.connected).length} 个在线 source'
                  : '${source.isDesktop ? '在电脑上运行' : '在 bridge 上运行'} · ${source.connected ? '活跃' : '休眠'}',
            ),
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              if (source != null && !source.connected)
                TextButton.icon(
                  onPressed: () => ref
                      .read(piSessionNotifierProvider)
                      ?.openSession(
                        sessionId: source.sessionId,
                        cwd: source.cwd,
                      ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('唤醒会话'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 快捷指令编辑器:chips 展示 + 添加/长按删除。
class QuickPromptsEditor extends ConsumerWidget {
  const QuickPromptsEditor({super.key});

  Future<void> _addPrompt(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增快捷指令'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(hintText: '例如: 跑一下测试并总结失败原因'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    // dialog 打开期间页面可能已被 pop,之后再用这个 ref 会直接抛异常
    if (!context.mounted) return;
    final current = ref.read(settingsProvider).quickPrompts;
    if (current.contains(text)) return;
    await ref.read(settingsProvider.notifier).setQuickPrompts([
      ...current,
      text,
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompts = ref.watch(settingsProvider.select((s) => s.quickPrompts));
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('快捷指令', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '新增',
                icon: const Icon(Icons.add, size: 18),
                onPressed: () => _addPrompt(context, ref),
              ),
            ],
          ),
          if (prompts.isEmpty)
            Text(
              '在聊天输入框为空时以 chips 显示,点按直接发送。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final prompt in prompts)
                  InputChip(
                    label: Text(
                      prompt.length > 20
                          ? '${prompt.substring(0, 20)}…'
                          : prompt,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    onDeleted: () => ref
                        .read(settingsProvider.notifier)
                        .setQuickPrompts(
                          prompts.where((p) => p != prompt).toList(),
                        ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 主题色色板。显示的是**种子色** —— 这样「橙色」看着才是橙的
/// (方案里的 primary 是该色相的 tone 40)。
class AccentPicker extends ConsumerWidget {
  const AccentPicker({super.key, required this.current});

  final AppAccent current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        for (final accent in AppAccent.values)
          Tooltip(
            message: accent.label,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: accent == current
                      ? colors.primary
                      : Colors.transparent,
                  width: 3,
                ),
              ),
              child: Material(
                color: accent.seed,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ref.read(settingsProvider.notifier).setAccent(accent);
                  },
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: accent == current
                        ? Icon(
                            Icons.check_rounded,
                            size: 26,
                            // 按种子色亮度决定黑白勾,而不是一律白色
                            color:
                                ThemeData.estimateBrightnessForColor(
                                      accent.seed,
                                    ) ==
                                    Brightness.dark
                                ? Colors.white
                                : Colors.black,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class StatusRow extends StatelessWidget {
  const StatusRow({super.key, required this.status});

  final PiConnStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final (icon, label, color) = switch (status) {
      PiConnStatus.connected => (Icons.check_circle, '已连接', piColors.success),
      PiConnStatus.connecting => (Icons.sync, '连接中…', piColors.warning),
      PiConnStatus.failed => (Icons.error, '连接失败', colors.error),
      PiConnStatus.disconnected => (Icons.link_off, '未连接', colors.outline),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

String _fmtTokens(int? v) {
  if (v == null) return '-';
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

/// 模型选择、思考档位、auto-compaction / auto-retry 开关。
class ModelBehaviorCard extends ConsumerStatefulWidget {
  const ModelBehaviorCard({super.key, required this.onChanged});

  /// Called after a change that may affect session stats.
  final VoidCallback onChanged;

  @override
  ConsumerState<ModelBehaviorCard> createState() => ModelBehaviorCardState();
}

class ModelBehaviorCardState extends ConsumerState<ModelBehaviorCard> {
  List<ModelInfo>? _models;
  List<String>? _levels;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (ref.read(piSessionProvider).status != PiConnStatus.connected) {
      if (mounted) {
        setState(() {
          _models = null;
          _levels = null;
        });
      }
      return;
    }
    final notifier = ref.read(piSessionNotifierProvider);
    if (notifier == null) return;
    setState(() => _loading = true);
    final models = await notifier.getAvailableModels();
    final levels = await notifier.getThinkingLevels();
    if (!mounted) return;
    setState(() {
      _models = models;
      _levels = levels;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(piSessionProvider.select((s) => s.status), (_, next) {
      if (next == PiConnStatus.connected) _load();
    });
    final piState = ref.watch(piSessionProvider);
    final autoRetry = ref.watch(settingsProvider.select((s) => s.autoRetry));
    final colors = Theme.of(context).colorScheme;
    final notifier = ref.read(piSessionNotifierProvider);
    final source = piState.selectedSource;
    final connected =
        piState.status == PiConnStatus.connected && source?.connected == true;
    // 模型/思考强度都是会话内设置,随时可改

    if (!connected) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Icon(Icons.cloud_off_outlined, color: colors.outline),
          title: const Text('未连接'),
          subtitle: const Text('连接后可配置模型与行为'),
        ),
      );
    }

    final models = _models;
    final levels = _levels;
    final currentModelKey = models
        ?.where((m) => m.id == piState.modelId)
        .firstOrNull
        ?.key;
    final currentLevel =
        (levels != null && levels.contains(piState.thinkingLevel))
        ? piState.thinkingLevel
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            DropdownButtonFormField<String>(
              initialValue: currentModelKey,
              decoration: const InputDecoration(
                labelText: '模型',
                prefixIcon: Icon(Icons.smart_toy_outlined),
              ),
              items: [
                for (final m in models ?? const <ModelInfo>[])
                  DropdownMenuItem(
                    value: m.key,
                    child: Text(
                      '${m.name} · ${m.provider}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: models == null || source?.supports('set_model') != true
                  ? null
                  : (key) async {
                      final m = models.firstWhere((x) => x.key == key);
                      final ok = await notifier?.setModel(m.provider, m.id);
                      // setModel 是网络往返,期间用户可能已退出本页,
                      // 那时 widget.onChanged 会调到已 dispose 的 setState
                      if (!mounted) return;
                      if (ok == true) widget.onChanged();
                    },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: currentLevel,
              decoration: const InputDecoration(
                labelText: '思考深度',
                prefixIcon: Icon(Icons.psychology_outlined),
              ),
              items: [
                for (final l in levels ?? const <String>[])
                  DropdownMenuItem(value: l, child: Text(l)),
              ],
              onChanged:
                  levels == null ||
                      source?.supports('set_thinking_level') != true
                  ? null
                  : (level) async {
                      if (level != null) {
                        await notifier?.setThinkingLevel(level);
                      }
                    },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动压缩上下文'),
              subtitle: const Text('上下文快满时自动压缩'),
              value: piState.autoCompactionEnabled,
              onChanged: source?.isHeadless == true
                  ? (v) => notifier?.setAutoCompaction(v)
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动重试'),
              subtitle: const Text('限流 / 5xx 等瞬时错误自动重试'),
              value: autoRetry,
              onChanged: source?.isHeadless == true
                  ? (v) => notifier?.setAutoRetry(v)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前会话信息 + token 统计 + 导出 HTML。
class SessionInfoCard extends ConsumerWidget {
  const SessionInfoCard({
    super.key,
    required this.stats,
    required this.onRefresh,
  });

  final SessionStats? stats;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piState = ref.watch(piSessionProvider);
    final colors = Theme.of(context).colorScheme;
    final connected =
        piState.status == PiConnStatus.connected &&
        piState.selectedSource?.connected == true;
    final canExport =
        connected && (piState.selectedSource?.supports('export_html') ?? false);
    final stats = this.stats;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('工作目录'),
            subtitle: Text(
              piState.cwd ?? '-',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('会话'),
            subtitle: Text(
              piState.sessionName ?? piState.sessionId ?? '-',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (stats != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tokens: 输入 ${_fmtTokens(stats.inputTokens)} · 输出 ${_fmtTokens(stats.outputTokens)} · 合计 ${_fmtTokens(stats.totalTokens)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '成本: \$${stats.costTotal?.toStringAsFixed(4) ?? '-'}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (stats.contextPercent != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (stats.contextPercent! / 100).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '上下文 ${stats.contextPercent}% (${_fmtTokens(stats.contextTokens)} / ${_fmtTokens(stats.contextWindow)})',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: connected ? onRefresh : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新统计'),
              ),
              TextButton.icon(
                onPressed: canExport
                    ? () async {
                        final path = await ref
                            .read(piSessionNotifierProvider)
                            ?.exportHtml();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                path != null ? '已导出: $path' : '导出失败',
                              ),
                            ),
                          );
                        }
                      }
                    : null,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('导出 HTML'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
