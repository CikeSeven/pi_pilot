import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';
import '../../common/tool_avatar.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'markdown_body.dart';
import 'message_card.dart';

/// 扩展自定义消息卡片。todo 列表(customType 含 todo)有专用渲染,
/// 其余按 Markdown 展示,customType 显示为标签。
class CustomItemView extends StatelessWidget {
  const CustomItemView({super.key, required this.item});

  final CustomItem item;

  @override
  Widget build(BuildContext context) {
    final piColors = PiColors.of(context);
    final todos = _todoItems(item);

    // 收起状态的 todo 面板不占位置
    if (todos != null && _hidden(item)) return const SizedBox.shrink();

    final isTodo = todos != null;
    final (headerBg, headerFg) = PiToolAvatar.colorsFor(
      isTodo ? PiToolCategory.files : PiToolCategory.extension,
      piColors,
    );
    final done = todos?.where((t) => t.status == PiTodoStatus.done).length ?? 0;

    return MessageCard(
      headerColor: headerBg,
      titleColor: headerFg,
      avatar: PiToolAvatar(
        icon: isTodo ? Icons.checklist_rounded : Icons.extension_outlined,
        category: isTodo ? PiToolCategory.files : PiToolCategory.extension,
        size: 32,
      ),
      // 「任务清单 3/6」比原样打印 `todo-progress-state` 有用得多
      title: Text(
        isTodo ? '任务清单 $done/${todos.length}' : item.customType,
        style: isTodo ? null : AppType.monoLabel(color: headerFg),
      ),
      subtitle: switch (isTodo ? _goal(item) : null) {
        final goal? => Text(goal),
        _ => null,
      },
      child: switch (todos) {
        final list? => _TodoList(todos: list),
        _ => PiMarkdown(text: item.text),
      },
    );
  }

  /// 解析 todo 列表。
  ///
  /// pi 真实发的是 `customType: "todo-progress-state"`,`data` 形如:
  /// ```json
  /// { "visible": true, "goal": "…", "offset": 0,
  ///   "items": [ {"status": "todo|partial|done", "text": "…"} ] }
  /// ```
  /// 之前只把 `status == 'completed'` 当完成 —— 而 pi 用的是 **`done`**,
  /// 所以线上每一条已完成的任务都渲染成了未勾选(实测 219 条)。
  static List<PiTodo>? _todoItems(CustomItem item) {
    if (!item.customType.toLowerCase().contains('todo')) return null;
    final raw = item.details?['todos'] ?? item.details?['items'];
    if (raw is! List || raw.isEmpty) return null;
    final todos = <PiTodo>[];
    for (final entry in raw) {
      if (entry is! Map) continue; // 单条坏数据不该让整个列表退回裸 markdown
      final text =
          entry['text'] ??
          entry['content'] ??
          entry['title'] ??
          entry['subject'];
      if (text is! String || text.isEmpty) continue;
      todos.add(PiTodo(text: text, status: _statusOf(entry)));
    }
    return todos.isEmpty ? null : todos;
  }

  static PiTodoStatus _statusOf(Map<dynamic, dynamic> entry) {
    if (entry['done'] == true ||
        entry['completed'] == true ||
        entry['checked'] == true) {
      return PiTodoStatus.done;
    }
    return switch (entry['status']) {
      'done' || 'completed' || 'complete' => PiTodoStatus.done,
      // pi 用 partial 表示进行中,之前它和未开始长得一模一样
      'partial' || 'in_progress' || 'active' => PiTodoStatus.inProgress,
      _ => PiTodoStatus.todo,
    };
  }

  /// `visible: false` 的 todo 面板在 TUI 里是收起的,手机上也不该占位置。
  static bool _hidden(CustomItem item) => item.details?['visible'] == false;

  /// 整体目标,渲染成列表标题。之前直接丢掉了。
  static String? _goal(CustomItem item) {
    final goal = item.details?['goal'];
    return goal is String && goal.trim().isNotEmpty ? goal.trim() : null;
  }
}

enum PiTodoStatus { todo, inProgress, done }

class PiTodo {
  const PiTodo({required this.text, required this.status});

  final String text;
  final PiTodoStatus status;
}

class _TodoList extends StatelessWidget {
  const _TodoList({required this.todos});

  final List<PiTodo> todos;

  @override
  Widget build(BuildContext context) {
    final piColors = PiColors.of(context);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final todo in todos)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 三态各有专属图标:pi 的 partial(进行中)以前和未开始长得一样。
                // 定高 20 的盒子让图标与首行文本垂直居中,而不是随多行文本贴顶。
                SizedBox(
                  height: 20,
                  child: Center(
                    child: switch (todo.status) {
                      PiTodoStatus.done => Icon(
                        Icons.check_circle,
                        size: 18,
                        color: piColors.success,
                      ),
                      PiTodoStatus.inProgress => Icon(
                        Icons.pending_outlined,
                        size: 18,
                        color: piColors.warning,
                      ),
                      PiTodoStatus.todo => Icon(
                        Icons.radio_button_unchecked,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    todo.text,
                    style: textTheme.bodyMedium?.copyWith(
                      color: switch (todo.status) {
                        PiTodoStatus.done => colors.onSurfaceVariant,
                        PiTodoStatus.inProgress => colors.onSurface,
                        PiTodoStatus.todo => colors.onSurface,
                      },
                      fontWeight: todo.status == PiTodoStatus.inProgress
                          ? FontWeight.w600
                          : null,
                      decoration: todo.status == PiTodoStatus.done
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 压缩/分支摘要:可展开的 chip + 面板。
class SummaryItemView extends StatefulWidget {
  const SummaryItemView({super.key, required this.item});

  final SummaryItem item;

  @override
  State<SummaryItemView> createState() => _SummaryItemViewState();
}

class _SummaryItemViewState extends State<SummaryItemView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, label) = widget.item.kind == 'compaction'
        ? (Icons.compress, '上下文已压缩')
        : (Icons.fork_right, '分支摘要');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          ActionChip(
            avatar: Icon(icon, size: 18, color: colors.onSurfaceVariant),
            label: Text('$label · ${_expanded ? '收起' : '查看摘要'}'),
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(PiShape.md),
              ),
              child: SelectableText(
                widget.item.summary,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
