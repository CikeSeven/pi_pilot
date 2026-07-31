import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';
import '../../common/tool_avatar.dart';
import '../../theme/motion.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
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
///
/// `statOnly` 纯统计模式:胶囊只报数量,不可点、无箭头、不展开。
/// 用于轮尾统计行 —— 工具卡已在消息流原位,展开只是重复。
class ToolGroupCard extends StatefulWidget {
  const ToolGroupCard({super.key, required this.tools, this.statOnly = false});

  final List<ToolItem> tools;

  /// 见类注释。
  final bool statOnly;

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
    final statOnly = widget.statOnly;
    final expanded = !statOnly && (_expanded || _anyRunning);
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
            onTap: statOnly
                ? null
                : () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!statOnly && _anyRunning)
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
                    !statOnly && running != null
                        ? '正在执行 $running…'
                        : single
                        ? _singleLabel(tools.first)
                        : '使用了 ${tools.length} 个工具',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: !statOnly && _anyRunning
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                // 迷你图标序列:按调用顺序排列,折叠也能看出顺序。
                if ((statOnly || !_anyRunning) && !single)
                  ..._miniIcons(piColors),
                if (!statOnly) ...[
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
              ],
            ),
          ),
        ),
        // 展开区:**直接**画每个工具的命令与执行结果。
        //
        // 以前这里为每个工具再套一张 ToolCard(自带 Card 外壳 + 自己的折叠态),
        // 于是变成「胶囊点开 → 大卡片 → 再点一次才看到输出」三层。
        // 现在胶囊是唯一的展开开关,点开就是内容。
        //
        // statOnly 时 expanded 恒为 false,这里始终渲染占位空盒 ——
        // 执行详情已在消息流原位,轮尾统计行不必重复一遍。
        AnimatedSize(
          duration: PiMotion.collapse,
          curve: PiMotion.collapseCurve,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < tools.length; i++)
                        _ToolDetail(
                          key: ValueKey(tools[i].key),
                          tool: tools[i],
                          // 多工具时每条之间拉一根细线,分块清楚;
                          // 第一条紧贴胶囊,不需要。
                          showDivider: i > 0,
                        ),
                    ],
                  ),
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
    final show = tools.length > maxShow ? tools.sublist(0, maxShow - 1) : tools;
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

/// 胶囊展开后的一条工具详情:**身份行 + 参数/命令 + 执行结果**。
///
/// 没有 Card、没有自己的折叠开关 —— 胶囊已经是展开开关了,再套一层就是
/// 用户抱怨的「小卡片里又一张大卡片,得点两次才看到输出」。
class _ToolDetail extends StatelessWidget {
  const _ToolDetail({super.key, required this.tool, required this.showDivider});

  final ToolItem tool;
  final bool showDivider;

  IconData get _icon => switch (tool.name) {
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final piColors = PiColors.of(context);
    final category = PiToolAvatar.categoryForTool(tool.name);
    final (bg, fg) = PiToolAvatar.colorsFor(category, piColors);
    // 手机作答的答案被 pi 包在错误信封里(agent-loop 的 block 分支写死
    // isError: true)。那是一次**成功**的作答,不能标红。
    final showError = tool.isError && !isAskAnswerOutput(tool);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showDivider)
          Divider(height: 17, thickness: 1, color: colors.outlineVariant),
        // 身份行:类别印章 + 工具名 + 状态位。不铺整行底色 ——
        // 胶囊已经担了分组的视觉外壳,这里再铺一条就又回到「卡中卡」。
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(PiShape.sm),
                ),
                child: Icon(_icon, size: 13, color: fg),
              ),
              const SizedBox(width: 8),
              // 裸 Text(tool.name):和工具卡一致,测试靠它定位具体工具。
              Expanded(
                child: Text(
                  tool.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (!tool.done)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: colors.primary,
                  ),
                )
              else
                Icon(
                  showError ? Icons.error_outline : Icons.check_circle_outline,
                  size: 16,
                  color: showError ? colors.error : colors.onSurfaceVariant,
                ),
            ],
          ),
        ),
        // 参数/命令横跨整行。不限行数:路径、命令看得全比挤成一行再 ellipsis 强。
        if (tool.argsSummary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              tool.argsSummary,
              style: AppType.monoLabel(color: colors.onSurfaceVariant),
            ),
          ),
        if (toolHasBody(tool)) ToolExecutionContent(item: tool),
      ],
    );
  }
}
