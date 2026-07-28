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
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final item = widget.item;
    final hasBody = item.output.isNotEmpty || _writeContent(item) != null;
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
    final piColors = PiColors.of(context);
    final path = item.args?['path'];
    switch (item.name) {
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
          text: item.output,
          style: AppType.monoSmall(color: piColors.codeWellFg),
        ),
      ),
    );
  }

  /// write 工具的落盘内容:参数里叫 content 或 text。
  static String? _writeContent(ToolItem item) {
    final args = item.args;
    if (args == null) return null;
    final content = args['content'] ?? args['text'];
    return content is String && content.isNotEmpty ? content : null;
  }

  /// 从 edit 参数(oldText/newText 或单条 edits)现算行级 diff。
  static List<DiffLine>? _diffFromArgs(ToolItem item) {
    final args = item.args;
    if (args == null) return null;
    final oldText = args['oldText'];
    final newText = args['newText'];
    if (oldText is String && newText is String) {
      return computeLineDiff(oldText, newText);
    }
    final edits = args['edits'];
    if (edits is List && edits.length == 1) {
      final edit = edits.first;
      if (edit is Map &&
          edit['oldText'] is String &&
          edit['newText'] is String) {
        return computeLineDiff(
          edit['oldText'] as String,
          edit['newText'] as String,
        );
      }
    }
    return null;
  }
}
