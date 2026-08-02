import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';
import '../../common/tool_avatar.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import '../../theme/typography.dart';
import 'glass_pill.dart';
import 'tool_card.dart';

/// 连续工具调用的聚合胶囊:**液态玻璃小胶囊,一行摘要,内容长在胶囊内部**。
///
/// 长任务一次刷几十张工具卡会把对话流冲得七零八落 —— 正文才是主角,
/// 工具调用是过程证据,默认收成一颗胶囊,要查证再点开。
///
/// 胶囊内容:
/// - 执行中:spinner + 当前工具的具体命令(强制展开,实时进度不能藏;
///   用户没点开过的话,完毕即自动收起);
/// - 单工具:类别小图标 +「bash · export LC_ALL…」,**展开时摘要行自己换成
///   完整命令全文**(多行),展开区只有执行结果 —— 命令不重复写两遍;
/// - 多工具:类别小图标 +「使用了 N 个工具」+ **迷你图标序列**
///   (按调用顺序排,扫一眼就知道用了哪些、什么顺序 —— 时序不丢),
///   展开后每条带自己的身份行 —— 否则看不出结果是谁的。
///
/// `statOnly` 纯统计模式:胶囊只报数量,不可点、不展开。
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

  ToolItem? get _runningTool {
    for (final t in widget.tools) {
      if (!t.done) return t;
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
    final runningTool = statOnly ? null : _runningTool;
    final tools = widget.tools;
    final single = tools.length == 1;

    // 类别色:单工具取它自己的类别色,多工具取灰蓝(工具类的代表色)。
    final leadCategory = PiToolAvatar.categoryForTool(tools.first.name);
    final (leadBg, leadFg) = PiToolAvatar.colorsFor(leadCategory, piColors);

    // 胶囊**自己就是整张卡片**:摘要行和执行结果都在它内部。
    //
    // 以前展开区是胶囊的**兄弟节点**(外面包一个 Column),所以无论怎么改
    // 它的边框背景,看上去都是「上面一颗胶囊、下面另一块东西」。
    // vertical 2:相邻胶囊间距收紧,不空廈。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: GlassPill(
        onTap: statOnly ? null : () => setState(() => _expanded = !_expanded),
        // statOnly 时 expanded 恒为 false → 传 null,胶囊保持一行 ——
        // 执行详情已在消息流原位,轮尾统计行不必重复一遍。
        expandedChild: !expanded
            ? null
            // 外层不再叠水平 padding:展开区里各渲染件自带内边距
            // (输出井 12、代码块/diff 14),再叠 12 就和摘要行的 12
            // 错开一倍,输出看起来比标题缩进两层。
            : single
            ? _singleContent(tools.first)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < tools.length; i++)
                    _ToolDetail(
                      key: ValueKey(tools[i].key),
                      tool: tools[i],
                      // 每条之间拉一根细线,分块清楚;
                      // 第一条紧贴摘要行,不需要。
                      showDivider: i > 0,
                    ),
                ],
              ),
        child: Row(
          // 顶部对齐:单工具展开时摘要行换成多行完整命令,Row 随之变高,
          // 默认的垂直居中会把领头图标往下带 —— 固定它在展开前的位置。
          crossAxisAlignment: CrossAxisAlignment.start,
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
                // 运行中也显示具体命令(转圈保留在左侧),不再换成「正在执行 X…」。
                single
                    ? _singleLabel(tools.first)
                    : runningTool != null
                    ? _singleLabel(runningTool)
                    : '使用了 ${tools.length} 个工具',
                // 展开后摘要行自己换成**完整命令全文**(多行不换行截断) ——
                // 折叠时是单行 ellipsis。同一行文字从「截断版」变「完整版」,
                // 展开区就不再需要重复写一遍命令。
                maxLines: (single || runningTool != null) && expanded
                    ? null
                    : 1,
                overflow: (single || runningTool != null) && expanded
                    ? null
                    : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: !statOnly && _anyRunning
                      ? colors.primary
                      : colors.onSurfaceVariant,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            // 单工具完成且失败:摘要行补一个错误标记。
            // 以前它住在展开区的身份行里,身份行删了以后单工具失败就没法
            // 一眼看出来。(成功不加标 —— 安静是默认态。)
            if (!statOnly &&
                single &&
                tools.first.done &&
                tools.first.isError &&
                !isAskAnswerOutput(tools.first)) ...[
              const SizedBox(width: 6),
              Icon(Icons.error_outline, size: 15, color: colors.error),
            ],
            // 迷你图标序列:按调用顺序排列,折叠也能看出顺序。
            if ((statOnly || !_anyRunning) && !single) ..._miniIcons(piColors),
          ],
        ),
      ),
    );
  }

  /// 单工具胶囊:「bash · export LC_ALL…」—— 名称 + **完整**命令。
  ///
  /// 折叠时 Text 自己会 ellipsis,视觉和以前一样;展开时同一行放开为多行,
  /// 完整原文直接显出来。用 fullToolCommand 而不是 argsSummary:
  /// 后者被 _clip 砍到 300 字符,长命令永远不能完整展示。
  String _singleLabel(ToolItem tool) {
    final command = fullToolCommand(tool);
    if (command == null) return tool.name;
    return '${tool.name} · $command';
  }

  /// 单工具展开内容:**只有执行结果**。
  ///
  /// 命令不再在这里重复 —— 展开时摘要行(上面那行)自己已经换成完整全文,
  /// 下面再写一遍就是画蛇添足。
  Widget _singleContent(ToolItem tool) {
    if (toolHasBody(tool)) return ToolExecutionContent(item: tool);
    // 完成了但没有任何输出:展开不能是空的,给一句交代。
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Text(
          '没有输出',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
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
        // 水平 12:与摘要行的 12 对齐(外层不再叠 padding)。
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
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
        // **完整**命令/路径:不限行数,看得全比截断强。
        // 输出井/代码块自带 12/14 内边距,与本行的 12 基本对齐。
        if (fullToolCommand(tool) case final command?)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
            child: Text(
              command,
              style: AppType.monoLabel(color: colors.onSurfaceVariant),
            ),
          ),
        if (toolHasBody(tool)) ToolExecutionContent(item: tool),
      ],
    );
  }
}

/// 展开区展示的**完整**命令/路径。
///
/// 胶囊摘要行是单行截断的 `argsSummary` —— 它还被 `_clip` 砍到 300 字符,
/// 长命令光看摘要行根本看不全。展开必须把原文摆出来:bash 取 `args.command`,
/// 文件类工具取 `args.path`,都不截断;其余工具退回 `argsSummary`。
String? fullToolCommand(ToolItem tool) {
  final args = tool.args;
  if (args != null) {
    final command = args['command'];
    if (command is String && command.isNotEmpty) return command;
    final path = args['path'];
    if (path is String && path.isNotEmpty) return path;
  }
  if (tool.argsSummary.isNotEmpty) return tool.argsSummary;
  return null;
}
