import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../common/tool_avatar.dart';
import '../../theme/motion.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'ansi_text.dart';
import 'code_block.dart';
import 'diff_view.dart';
import 'message_actions_sheet.dart';
import 'message_card.dart';

const _kOutputMaxHeight = 280.0;

/// 插件 `@juicesharp/rpiv-ask-user-question` 注入的问卷工具。
const _kAskUserQuestion = 'ask_user_question';

/// 工具调用卡片:按工具类型选择结构化渲染(read 行号/edit diff/write 代码)。
class ToolCard extends ConsumerStatefulWidget {
  const ToolCard({super.key, required this.item});

  final ToolItem item;

  @override
  ConsumerState<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends ConsumerState<ToolCard> {
  late bool _expanded = !widget.item.done;

  IconData get _icon => switch (widget.item.name) {
    'bash' => Icons.terminal,
    'read' => Icons.visibility_outlined,
    'write' || 'edit' => Icons.edit_note,
    'grep' || 'find' => Icons.search,
    'ls' => Icons.folder_outlined,
    _kAskUserQuestion => Icons.help_outline,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final item = widget.item;
    // 问卷的内容全在**参数**里,不在 output 里。不把它算进 hasBody,
    // 卡片就永远不可展开 —— 手机上只剩一个转不完的圈,看不出在等什么。
    final hasBody =
        item.output.isNotEmpty ||
        _writeContent(item) != null ||
        _questions(item) != null;
    final category = PiToolAvatar.categoryForTool(item.name);
    // 整条身份行铺类别色 —— 之前这 7 组色只染了一个 36dp 头像,
    // 埋在灰卡里根本看不出 bash / 读 / 写 / 搜索的区别。
    final (headerBg, headerFg) = PiToolAvatar.colorsFor(category, piColors);

    return MessageCard(
      headerColor: headerBg,
      titleColor: headerFg,
      avatar: PiToolAvatar(icon: _icon, category: category, size: 32),
      // 裸 Text(item.name):测试点它来展开完成态的卡片
      title: Text(item.name),
      // 参数摘要放**副行**。它是内容不是状态,塞进 trailing 既挤又语义错 ——
      // 而且 trailing 的宽度必须是可预期的。
      subtitle: item.argsSummary.isEmpty
          ? null
          : Text(item.argsSummary, style: AppType.monoLabel(color: headerFg)),
      onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
      onLongPress: item.output.isEmpty
          ? null
          : () => showMessageActions(context, ref, item),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      // trailing 只留状态位:两个槽都是定宽 20,spinner(16)与完成图标(18)
      // 各自居中 —— 否则状态切换瞬间整行宽度跳变
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!item.done)
            SizedBox(
              width: 20,
              height: 20,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: headerFg,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              width: 20,
              height: 20,
              child: Center(
                child: Icon(
                  item.isError
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 18,
                  color: item.isError ? colors.error : headerFg,
                ),
              ),
            ),
          if (hasBody) ...[
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: PiMotion.quick,
              curve: PiMotion.enter,
              child: Icon(Icons.expand_more, size: 18, color: headerFg),
            ),
          ],
        ],
      ),
      child: AnimatedSize(
        duration: PiMotion.quick,
        curve: PiMotion.enter,
        alignment: Alignment.topCenter,
        child: !_expanded || !hasBody
            ? const SizedBox(width: double.infinity)
            : _buildBody(context, item),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ToolItem item) {
    final path = item.args?['path'];
    switch (item.name) {
      case _kAskUserQuestion:
        final questions = _questions(item);
        if (questions != null) {
          return _QuestionnaireView(
            questions: questions,
            answered: item.done,
            output: item.output,
          );
        }
      case 'read':
        return CodeBlock(
          code: item.output,
          language: path is String ? languageForPath(path) : null,
          showLineNumbers: true,
          firstLineNumber: switch (item.args?['offset']) {
            final int offset when offset > 0 => offset,
            _ => 1,
          },
          maxHeight: _kOutputMaxHeight,
        );
      case 'edit':
        if (looksLikeUnifiedDiff(item.output)) {
          return DiffView(diffText: item.output, maxHeight: _kOutputMaxHeight);
        }
        final diff = _diffFromArgs(item);
        if (diff != null) {
          return DiffView(lines: diff, maxHeight: _kOutputMaxHeight);
        }
      case 'write':
        final content = _writeContent(item);
        if (content != null) {
          return CodeBlock(
            code: content,
            language: path is String ? languageForPath(path) : null,
            maxHeight: _kOutputMaxHeight,
          );
        }
    }
    // 默认:mono + ANSI 解析的输出井(固定井底,保证前景对比度与主题无关)
    return _outputWell(context, item.output);
  }

  /// 问卷题目。只在参数确实带着题目列表时返回,否则回落到普通工具卡渲染 ——
  /// 参数在断层里丢了(历史 toolResult 常常没有 args)也不能把卡片搞坏。
  static List<Map<String, dynamic>>? _questions(ToolItem item) {
    if (item.name != _kAskUserQuestion) return null;
    final raw = item.args?['questions'];
    if (raw is! List || raw.isEmpty) return null;
    final parsed = [
      for (final entry in raw)
        if (entry is Map) Map<String, dynamic>.from(entry),
    ];
    return parsed.isEmpty ? null : parsed;
  }

  /// write 工具的落盘内容:参数里叫 content 或 text。
  static String? _writeContent(ToolItem item) {
    final args = item.args;
    if (args == null) return null;
    final content = args['content'] ?? args['text'];
    return content is String && content.isNotEmpty ? content : null;
  }

  /// 从 edit 参数(oldText/newText 或 edits 列表)现算行级 diff。
  ///
  /// 多块编辑必须逐块算再拼起来:工具的 output 只是
  /// "Successfully replaced N block(s)" 这类成功文案,不含任何 diff 内容。
  /// 以前只处理单块,多块就返回 null 掉到默认分支,把那句文案直接显示出来。
  static List<DiffLine>? _diffFromArgs(ToolItem item) {
    final args = item.args;
    if (args == null) return null;
    final oldText = args['oldText'];
    final newText = args['newText'];
    if (oldText is String && newText is String) {
      return computeLineDiff(oldText, newText);
    }
    final edits = args['edits'];
    if (edits is! List || edits.isEmpty) return null;

    final blocks = <List<DiffLine>>[];
    for (final edit in edits) {
      if (edit is! Map) continue;
      final from = edit['oldText'];
      final to = edit['newText'];
      if (from is! String || to is! String) continue;
      blocks.add(computeLineDiff(from, to));
    }
    if (blocks.isEmpty) return null;
    if (blocks.length == 1) return blocks.single;

    // 多块之间插 hunk 头,让用户看清这是第几处修改(DiffView 会给它浅底)
    final merged = <DiffLine>[];
    for (var i = 0; i < blocks.length; i++) {
      merged.add(
        DiffLine(DiffLineKind.hunk, '@@ 第 ${i + 1}/${blocks.length} 处修改 @@'),
      );
      merged.addAll(blocks[i]);
    }
    return merged;
  }
}

/// 默认输出井:mono + ANSI 解析,固定井底保证前景对比度与主题无关。
Widget _outputWell(BuildContext context, String text) {
  final piColors = PiColors.of(context);
  return Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: _kOutputMaxHeight),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: piColors.codeWellBg,
      borderRadius: BorderRadius.circular(PiShape.md),
      border: Border.all(color: piColors.codeWellBorder),
    ),
    child: SingleChildScrollView(
      child: AnsiText(
        text: text,
        style: AppType.monoSmall(color: piColors.codeWellFg),
      ),
    ),
  );
}

/// 问卷的只读呈现。
///
/// 插件 `@juicesharp/rpiv-ask-user-question` 的问卷是电脑端 TUI 的覆盖层
/// (`ctx.ui.custom()`),**不走** pi 的 select/confirm/input/editor 对话框协议,
/// 所以手机既收不到 `extension_ui_request`,也没有任何可编程的应答入口 ——
/// 插件全仓只有两处 `pi.events.emit`、零处 `pi.events.on`,答案唯一入口是
/// TUI 组件内部的键盘输入。
///
/// 因此手机能做的只有一件事:把电脑正在等什么如实显示出来。题目和选项本来就
/// 随 `tool_execution_start` 的 args 一起到了手机,以前只是没人渲染,于是卡片
/// 上只剩一个转不完的圈,看不出在等人作答。
class _QuestionnaireView extends StatelessWidget {
  const _QuestionnaireView({
    required this.questions,
    required this.answered,
    required this.output,
  });

  final List<Map<String, dynamic>> questions;
  final bool answered;
  final String output;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!answered) _WaitingHint(),
        for (var i = 0; i < questions.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _QuestionBlock(question: questions[i], index: i),
        ],
        // 作答结果是模型看到的那份信封,答完了才有意义
        if (answered && output.isNotEmpty) ...[
          const SizedBox(height: 12),
          _outputWell(context, output),
        ],
      ],
    );
  }
}

/// 「去电脑上作答」提示。手机上无法应答是硬约束,必须说清楚,
/// 否则用户会一直等这张卡自己动。
class _WaitingHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.keyboard_outlined,
            size: 18,
            color: colors.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '电脑端正在等你作答 · 手机上只能查看',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个问题:序号 + header 标签 + 题干 + 选项。
class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({required this.question, required this.index});

  final Map<String, dynamic> question;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final header = question['header'];
    final text = question['question'];
    final multi = question['multiSelect'] == true;
    final options = question['options'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${index + 1}.',
              style: AppType.monoLabel(color: colors.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            if (header is String && header.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(PiShape.xs),
                ),
                child: Text(
                  header,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (multi) ...[
              const SizedBox(width: 6),
              Text(
                '可多选',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.primary,
                ),
              ),
            ],
          ],
        ),
        if (text is String && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        if (options is List)
          for (final option in options)
            if (option is Map) _OptionRow(option: option),
      ],
    );
  }
}

/// 一个选项:标签 + 说明。带 preview 的额外标一下,
/// 那是电脑上才看得到的并排对比内容。
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option});

  final Map option;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = option['label'];
    final description = option['description'];
    final preview = option['preview'];
    final hasPreview = preview is String && preview.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.circle, size: 6, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label is String ? label : '',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (hasPreview)
                      Text(
                        '含预览',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                if (description is String && description.isNotEmpty)
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
