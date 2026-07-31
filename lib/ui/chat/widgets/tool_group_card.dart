import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';
import '../../common/tool_avatar.dart';
import '../../theme/motion.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import 'glass_pill.dart';
import 'tool_card.dart';

/// 连续工具调用的聚合胶囊:**液态玻璃小胶囊,一行摘要,点开才展开全部卡片**。
///
/// 长任务一次刷几十张工具卡会把对话流冲得七零八落 —— 正文才是主角,
/// 工具调用是过程证据,默认收成一颗胶囊,要查证再点开。
///
/// 胶囊内容:
/// - 执行中:spinner +「正在执行 read…」(强制展开,实时进度不能藏);
/// - 单工具:类别小图标 +「bash · export LC_ALL…」(信息不丢);
/// - 多工具:类别小图标 +「使用了 N 个工具」+ **迷你图标序列**
///   (按调用顺序排,扫一眼就知道用了哪些、什么顺序 —— 时序不丢)。
class ToolGroupCard extends StatefulWidget {
  const ToolGroupCard({super.key, required this.tools});

  final List<ToolItem> tools;

  @override
  State<ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<ToolGroupCard> {
  bool _expanded = false;

  bool get _anyRunning => widget.tools.any((t) => !t.done);

  String? get _runningName {
    for (final t in widget.tools) {
      if (!t.done) return t.name;
    }
    return null;
  }

  IconData _iconFor(String name) => switch (name) {
    'bash' => Icons.terminal,
    'read' => Icons.visibility_outlined,
    'write' || 'edit' => Icons.edit_note,
    'grep' || 'find' => Icons.search,
    'ls' => Icons.folder_outlined,
    'ask_user_question' => Icons.help_outline,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final expanded = _expanded || _anyRunning;
    final running = _runningName;
    final tools = widget.tools;
    final single = tools.length == 1;

    // 类别色:单工具取它自己的类别色,多工具取灰蓝(工具类的代表色)。
    final leadCategory = PiToolAvatar.categoryForTool(tools.first.name);
    final (leadBg, leadFg) = PiToolAvatar.colorsFor(leadCategory, piColors);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 液态玻璃胶囊:和思考块折叠态共用 GlassPill,形态统一。
        // vertical 2:相邻胶囊间距收紧,不空廈。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: GlassPill(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                  if (_anyRunning)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    )
                  else
                    // 领头的类别小印章:胶囊的「身份戳」。
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: leadBg,
                        borderRadius: BorderRadius.circular(PiShape.sm),
                      ),
                      child: Icon(
                        _iconFor(tools.first.name),
                        size: 12,
                        color: leadFg,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      running != null
                          ? '正在执行 $running…'
                          : single
                          ? _singleLabel(tools.first)
                          : '使用了 ${tools.length} 个工具',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _anyRunning
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  // 迷你图标序列:按调用顺序排列,折叠也能看出顺序。
                  if (!_anyRunning && !single) ..._miniIcons(piColors),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: PiMotion.collapse,
                    curve: PiMotion.collapseCurve,
                    child: Icon(
                      Icons.expand_more,
                      size: 15,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 展开区:ToolCard 自带 margin,这里不加水平 padding。
        AnimatedSize(
          duration: PiMotion.collapse,
          curve: PiMotion.collapseCurve,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final tool in widget.tools)
                      ToolCard(key: ValueKey(tool.key), item: tool),
                  ],
                ),
        ),
      ],
    );
  }

  /// 单工具胶囊:「bash · export LC_ALL…」—— 名称 + 参数摘要,信息不丢。
  String _singleLabel(ToolItem tool) {
    if (tool.argsSummary.isEmpty) return tool.name;
    return '${tool.name} · ${tool.argsSummary}';
  }

  /// 迷你图标序列:每个工具一枚 16px 小印章,按调用顺序排。
  /// 超过 6 个时前 5 个 + 「+N」,胶囊不爆宽。
  List<Widget> _miniIcons(PiColors piColors) {
    final tools = widget.tools;
    const maxShow = 6;
    final show = tools.length > maxShow
        ? tools.sublist(0, maxShow - 1)
        : tools;
    final rest = tools.length - show.length;
    return [
      const SizedBox(width: 4),
      for (final t in show) ..._stamp(t, piColors),
      if (rest > 0)
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            '+$rest',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }

  List<Widget> _stamp(ToolItem tool, PiColors piColors) {
    final category = PiToolAvatar.categoryForTool(tool.name);
    final (bg, fg) = PiToolAvatar.colorsFor(category, piColors);
    return [
      const SizedBox(width: 3),
      Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(PiShape.sm),
        ),
        child: Icon(_iconFor(tool.name), size: 10, color: fg),
      ),
    ];
  }
}
