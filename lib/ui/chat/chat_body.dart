import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../state/device_manager.dart';
import '../../state/pi_session.dart';
import '../sessions/devices_page.dart';
import '../theme/paper.dart';
import '../theme/shapes.dart';
import '../theme/typography.dart';
import 'chat_scroll_anchor.dart';
import 'widgets/chat_item_view.dart';
import 'widgets/composer.dart';
import 'widgets/message_nav_rail.dart';
import 'widgets/message_timestamp.dart';
import 'widgets/quick_panel.dart';
import 'widgets/scroll_to_bottom_button.dart';
import 'widgets/tool_group_card.dart';
import 'widgets/ui_request_card.dart';

/// 对话主体。**不再自带 `Scaffold`** —— 那一层上移到了 `AppShell`,
/// 这样才有地方挂抽屉。
class ChatBody extends ConsumerStatefulWidget {
  const ChatBody({super.key, this.topPadding = 0});

  /// 顶部留空(灵动岛高度 + 状态栏)。
  /// 列表静止时第一项在岛下面;滚动时内容滚入顶部渐变区渐隐。
  final double topPadding;

  @override
  ConsumerState<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<ChatBody> {
  final _input = TextEditingController();

  /// 按**下标**定位的列表。
  ///
  /// 换掉 `ListView` + `ScrollController` 不是为了好看:普通惰性列表只能按
  /// 像素跳,而聊天行高差几十倍(一条用户消息 vs 一个大 bash 输出井),
  /// `maxScrollExtent` 又只是按已建行平均高度外推的**估算值**。于是
  /// 「跳到第 N 条」「插入历史后停在原处」「滚动条位置」三件事全都建立在
  /// 一个不成立的假设上 —— 这就是卡顿之外那两个 bug 的共同根因。
  ///
  /// `ScrollablePositionedList` 直接按 index + alignment 定位,和行高解耦。
  final _itemScroll = ItemScrollController();
  final _itemPositions = ItemPositionsListener.create();
  String _inputText = '';

  /// 快捷指令没有输入框可清,用它挡住连点(否则会开两个会话、发两条消息)。
  bool _sending = false;

  /// 悬浮输入卡的实测高度,用来给列表留底部空间。
  ///
  /// **不能写死**:输入卡高 = 84 + 系统手势条 inset,再加上展开的快捷面板/
  /// 投递芯片。手势条 48dp 的机器上写死 96 会把最后一条消息压掉 28dp。
  /// 默认值 140:足够覆盖手势条 48dp + 内容 92dp 的常见情况,
  /// 首帧测量成功后会被实测值覆盖。
  final _composerKey = GlobalKey();
  double _composerHeight = 140;

  /// 派生数据缓存:时间标注标志。
  ///
  /// 只依赖 items 列表本身,但以前在 build 里全量重扫一遍 items。
  /// 靠 revision 判定失效,同一份列表只算一次。
  int _derivedRevision = -1;
  List<bool> _timestampFlagCache = const [];

  /// 渲染行:由 items 派生,连续的 ≥2 个 ToolItem 聚合成一个工具组行。
  /// 下标/时间戳全都按行维度计算。
  List<_ChatRow> _rows = const [];

  /// 行主键 → 行下标。加载更早的历史后靠它把视口锚回同一条消息。
  Map<String, int> _rowIndexByKey = const {};

  /// 会话切换后待执行的「跳到底部」。
  ///
  /// 加载完的落点必须是最新消息 —— 长会话停在第一条,用户要滑很久。
  /// 按下标定位之后这件事变得很便宜:`initialScrollIndex` 一步到位,
  /// 不再需要「连推 6 帧、每帧朝新的 maxScrollExtent 再跳一次」那条链。
  String? _lastSessionToken;

  /// 一次性的「首帧落到底部」标记。
  ///
  /// 必须和 [_lastSessionToken] 分开:切会话那一帧 items 通常还是空的,
  /// 此时跳等于没跳。留着这个 token 等历史真的刷进来再跳一次,然后清掉 ——
  /// 清掉是关键,否则用户往上翻历史会被反复拽回底部。
  String? _pendingInitialBottomToken;

  /// 离顶部还有几行就开始预加载。
  ///
  /// 从「离顶部 600px」改成「首个可见行下标 ≤ 3」:像素阈值在行高不均的
  /// 列表里没有稳定含义(一个大输出井就能顶掉整个提前量),行下标有。
  static const _autoLoadRowThreshold = 3;

  /// 自动加载的重入闸:一次滚动里 positions 会反复通知。
  bool _autoLoading = false;

  // -- 消息导航轨道 --------------------------------------------------------

  /// 用户消息锚点(行下标 + 预览),由 _syncDerived 顺手收集。
  List<NavAnchor> _navAnchors = const [];

  /// 轨道显隐。**用 ValueNotifier 而不是 setState** —— 显隐每次翻转都
  /// 重建整个 ChatBody 的话,会连带把 ListView 可见项全部重建一遍
  /// (markdown 解析 + 语法高亮),滚动一停一动就掉帧。
  final _railVisible = ValueNotifier<bool>(false);
  bool _railInteracting = false;
  Timer? _railHideTimer;
  static const _railHideDelay = Duration(seconds: 2);

  /// 滚动进度(0~1),滚动时逐帧更新,驱动轨道游标连续滑动。
  ///
  /// 必须是 listenable:滚动本身不触发 ChatBody rebuild,
  /// 游标如果吃 build 里现算的值,会停在滚动前的位置不动。
  final _scrollProgress = ValueNotifier<double>(0);

  /// 首个可见行在完整行表里的下标(由 [_itemPositions] 推导)。
  int _firstVisibleRow = 0;

  /// 视口是否贴在列表**真正的底部端点**上(决定流式期间是否跟随)。
  ///
  /// 判据不能用「最后一行的下标出现在可见集里」:一条长回答本身就可能比
  /// 视口高好几屏,用户在它内部往上翻了很远,它**仍然**是最后一个可见行。
  /// 那样每来一个 token 都会判成「在底部」并跳一次,视口被反复按回那一行的
  /// 顶部 —— 真机症状是「每多生成一点文字列表就向上抽动一下」,而且人根本
  /// 没法往上翻。
  ///
  /// 改成看终点槽([_tailSlots] 里那 1px 的哨兵)可见不可见:它在视野里才算
  /// 真的到底了。
  bool _tailPinned = true;

  /// 列表顶部是否占着一个「加载更早」槽位。
  ///
  /// 只在「桥上还留着更早的历史」时出现。本地不再做窗口化——尾部窗口
  /// 是为绕开普通 ListView 无法按下标 seek 而生的,按下标定位之后它只剩
  /// 副作用(头部插入让 offset 变化 → 位置乱窜),所以整套拆掉了。
  bool _hasEarlierSlot(PiState state) => state.hasMoreHistory;

  /// 行下标 → 列表槽位。
  int _slotOfRow(int rowIndex) => rowIndex + _leadingSlots;

  /// 列表槽位 → 行下标(负数会被夹到 0:那是「加载更早」槽)。
  int _rowOfSlot(int slot) {
    final row = slot - _leadingSlots;
    if (row < 0) return 0;
    if (row >= _rows.length) return _rows.isEmpty ? 0 : _rows.length - 1;
    return row;
  }

  /// 当前列表顶部的额外槽位数(0 或 1)。build 时同步。
  int _leadingSlots = 0;

  /// 列表尾部的额外槽位数:输入卡占位 + 1px 终点哨兵。
  ///
  /// 底部留白原来是 `padding` 的一部分。padding 不是子项,拿不到可见性,
  /// 于是「到底了没有」只能靠最后一行的下标去猜 —— 那个判据对高个流式行
  /// 是错的(见 [_tailPinned])。把留白改成真实槽位,再追一个 1px 哨兵当
  /// 终点,「到底」就变成一个可以直接观测的事实。
  static const int _tailSlots = 2;

  /// 终点哨兵的槽位下标(列表最后一个槽)。
  int get _terminalSlot => _leadingSlots + _rows.length + _trailingRequestSlots + 1;

  /// 尾部「待处理 UI 请求」占的槽位数(0 或 1)。build 时同步。
  int _trailingRequestSlots = 0;

  /// 滚动位置 → 锚点序号比例(0~1)。
  ///
  /// 不做「像素比例 = 进度」—— 那样峰值位置和第几条消息对不上。
  /// 先把像素比例换算成行号,再在相邻锚点之间按行号线性插序号:
  /// 视口正在看第 i 条消息,进度就严格落在第 i 个大节点上;
  /// 两条消息之间连续插值,既严格匹配又不阶跃。
  ///
  /// 焦点现在从**真实布局出的首个可见行下标**推导,不再拿
  /// `pixels / maxScrollExtent` 当行号比例 —— 后者在行高不均的列表里
  /// 本身就是错的映射(滚动条位置对不上第几条消息的根因)。
  double _anchorFocusT() => anchorFocusOf(_navAnchors, _firstVisibleRow);

  void _showRail() {
    _railHideTimer?.cancel();
    _railVisible.value = true;
  }

  void _scheduleRailHide() {
    _railHideTimer?.cancel();
    _railHideTimer = Timer(_railHideDelay, () {
      if (!_railInteracting && mounted) _railVisible.value = false;
    });
  }

  /// 跳到某一行:按**下标**直接定位。
  ///
  /// 旧实现是「按比例粗跳 + ensureVisible 精修链」,两头都不可靠:比例假设
  /// 行高均等;而惰性列表只建视口附近,粗跳落点偏了目标行根本没被建出来,
  /// `GlobalKey.currentContext` 恒为 null,几帧后静默放弃 —— 这就是
  /// 「拖到某处列表动一下就不动、根本没定位过去」的直接原因。
  ///
  /// alignment 0.08:目标行落在视口偏上一点,上文留一线,不贴死顶边。
  void _jumpToRow(int rowIndex) {
    if (rowIndex < 0 || rowIndex >= _rows.length) return;
    _showRail();
    _scheduleRailHide();
    if (!_itemScroll.isAttached) return;
    _itemScroll.jumpTo(index: _slotOfRow(rowIndex), alignment: 0.08);
    // 轨道游标立刻落到目标,不等 positions 回调 —— 松手即到位。
    _firstVisibleRow = rowIndex;
    _scrollProgress.value = _anchorFocusT();
  }

  @override
  void initState() {
    super.initState();
    _itemPositions.itemPositions.addListener(_onPositions);
  }

  /// 可见项变化的统一入口(替代旧的 `ScrollController` 监听)。
  ///
  /// 帧路径上只做三件轻量事:算首个可见行、更新游标进度、必要时补历史。
  /// **不再在这里调 `_syncDerived`** —— 派生行表只依赖 items,归 build 管;
  /// 滚动期间反复重算是白烧帧时间。
  void _onPositions() {
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;

    // 下标最小的槽位 = 用户正在看的那一行(它的前缘可能已经滚到视口上方)。
    var firstSlot = positions.first.index;
    for (final p in positions) {
      if (p.index < firstSlot) firstSlot = p.index;
    }
    _firstVisibleRow = _rowOfSlot(firstSlot);
    _scrollProgress.value = _anchorFocusT();

    // 终点哨兵在视野里 = 真的贴着底。用户往上翻一点它就离开可见集,
    // 跟随随即让位 —— 这是个可观测的事实,不是从行下标推断出来的。
    final terminal = _terminalSlot;
    _tailPinned = positions.any(
      (p) => p.index == terminal && p.itemTrailingEdge <= 1.001,
    );

    if (_autoLoading) return;
    final state = ref.read(piSessionProvider);
    if (!state.hasMoreHistory || state.loadingEarlier) return;
    if (firstSlot > _autoLoadRowThreshold) return;

    _autoLoading = true;
    unawaited(
      _loadEarlier().whenComplete(() {
        // 下一帧再放闸:本帧里 positions 还会因为锚点跳转再通知几次。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoLoading = false;
        });
      }),
    );
  }


  /// 「加载更早」—— 联网把更早的历史补进列表,视口按 **稳定行主键** 锚住不动。
  ///
  /// 桥为了不撞爆手机的 2MB 套接字缓冲只发 entries 的尾巴(全量快照实测到过
  /// 10.27MB),更早的留在桥上。所以滚到本地头部不等于历史到头了。
  ///
  /// 旧实现是「记下 maxScrollExtent,插入后按增量 jumpTo 补偿」。那个补偿量
  /// 恒定偏:头部插入几十行后新的 `maxScrollExtent` 仍然只是按已建行平均高度
  /// 外推的估算值,和真实高度增量没有确定关系 —— 偏多少不可预测,这就是
  /// 「加载完更早的消息后列表乱窜、找不到跑哪去了」的根因。
  ///
  /// 现在改成:插入前记下**当前屏内第一条内容行的主键**和它的前缘位置,
  /// 插入后在新行表里按同一个主键查新下标,连原前缘位置一起给回去。
  ///
  /// 为什么不用「旧下标 + 插入行数」推算:行表是从 items 派生的,一次同步里
  /// 工具行/统计行的数量都可能变,而且 `await` 之后 Riverpod 可能已经重建过
  /// `_rows`,行增量根本算不准(会算成 0)。主键是唯一可信的身份。
  Future<void> _loadEarlier() async {
    final anchor = _currentViewportAnchor();
    final ok = await ref.read(piSessionNotifierProvider)?.loadEarlierHistory();
    if (!mounted || ok != true || anchor == null) return;

    // 等这一帧把新行表建出来,再按主键查新下标 —— 此时 build 已经跑过
    // _syncDerived,_rowIndexByKey 是新的。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScroll.isAttached) return;
      final newRow = _rowIndexByKey[anchor.rowKey];
      // 查不到说明那一条被压缩/替换掉了,这时候硬跳反而更乱,不动为上。
      if (newRow == null) return;
      _itemScroll.jumpTo(
        index: _slotOfRow(newRow),
        alignment: anchor.leadingEdge,
      );
    });
  }

  /// 当前**屏内**第一条内容行的锚点(主键 + 前缘归一化位置)。
  ///
  /// 两处讲究:
  /// - 只取 `itemLeadingEdge` 在 0~1 之间的项。`ItemScrollController.jumpTo`
  ///   的 alignment 是视口对齐值,喂负数不成立;而下标最小的那一项通常
  ///   已经有一部分滚到视口上方去了(前缘为负)。
  /// - 跳过加载槽和统计行:前者不是消息,后者不对应任何 item、没有稳定身份。
  ViewportAnchor? _currentViewportAnchor() {
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return null;

    ViewportAnchor? best;
    var bestEdge = double.infinity;
    for (final p in positions) {
      if (p.itemLeadingEdge < 0 || p.itemLeadingEdge > 1) continue;
      final row = p.index - _leadingSlots;
      if (row < 0 || row >= _rows.length) continue;
      final key = _primaryKeyOf(_rows[row]);
      if (key == null) continue;
      // 屏内最靠上的那一条。
      if (p.itemLeadingEdge < bestEdge) {
        bestEdge = p.itemLeadingEdge;
        best = ViewportAnchor(rowKey: key, leadingEdge: p.itemLeadingEdge);
      }
    }
    return best;
  }

  void _syncDerived(PiState state) {
    if (_derivedRevision == state.revision) return;
    _derivedRevision = state.revision;
    final items = state.items;

    // 派生渲染行。**按轮分段**(UserItem 开头),完成轮与进行轮统一布局:
    //
    // - 工具原位:**每个工具各自一颗胶囊**,位置和实际执行顺序一致,
    //   实时进度看得见;连续调用不再合并 —— 每条都能单独展开看命令和结果。
    // - 轮尾追加一颗**纯统计**胶囊(「使用了 N 个工具」+ 迷你图标),
    //   不可点、不展开 —— 一轮几十次调用要有个总账,明细已在流里逐条列出。
    final rows = <_ChatRow>[];
    final rowTimes = <DateTime?>[];

    void addRow(_ChatRow row, DateTime? time) {
      rows.add(row);
      rowTimes.add(time);
    }

    void buildSegment(int start, int end) {
      if (start >= end) return;

      // 空 AssistantItem(纯工具调用回合产生)不产生行,也不打断工具收集。
      bool isEmptyAssistant(ChatItem i) =>
          i is AssistantItem &&
          i.complete &&
          i.text.isEmpty &&
          i.thinking.isEmpty;

      // 按原始顺序流式扫描,每个工具各自一行 —— 连续调用不合并。
      final allTools = <ToolItem>[];
      for (var i = start; i < end; i++) {
        final item = items[i];
        if (item is ToolItem) {
          allTools.add(item);
          addRow(_ToolGroupRow(List.unmodifiable([item])), null);
        } else if (!isEmptyAssistant(item)) {
          addRow(_SingleRow(item), timeOf(item));
        }
      }

      // 轮尾统计胶囊。不注册工具 key:那些 key 属于流里的原位工具行,
      // 重复注册会把滚动锚点从工具行抢过来。
      if (allTools.isNotEmpty) {
        addRow(_ToolStatRow(List.unmodifiable(allTools)), null);
      }
    }

    var segStart = 0;
    for (var i = 1; i < items.length; i++) {
      if (items[i] is UserItem) {
        buildSegment(segStart, i);
        segStart = i;
      }
    }
    buildSegment(segStart, items.length);

    // 时间戳标志按行算:工具行/组行无时间(null 跳过),
    // 和原来按 items 算的语义一致 —— 时间戳只看 user/assistant。
    final flags = List<bool>.filled(rows.length, false);
    DateTime? prev;
    for (var i = 0; i < rows.length; i++) {
      final time = rowTimes[i];
      if (time == null) continue;
      flags[i] = shouldShowTimestamp(prev, time);
      prev = time;
    }

    _rows = rows;
    _timestampFlagCache = flags;
    // 主键 → 行下标。加载更早的历史后要靠它把视口重新锚回同一条消息上
    // —— 不能用「旧下标 + 插入行数」推算:行表是从 items 派生的,
    // 一次同步里工具行/统计行的数量都可能变,推算出来的位置不可信。
    // 统计行不注册:它不属于任何 item,没有稳定身份。
    final keys = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final key = _primaryKeyOf(rows[i]);
      if (key != null) keys[key] = i;
    }
    _rowIndexByKey = keys;
    // 导航轨道锚点:每行用户消息一个刻度。
    _navAnchors = [
      for (var i = 0; i < rows.length; i++)
        if (rows[i] case _SingleRow(item: final UserItem u))
          NavAnchor(rowIndex: i, preview: u.text, time: u.time),
    ];
  }

  /// 一行的稳定主键(和渲染时的 widget key 同源)。
  ///
  /// 统计行返回 null —— 它是轮尾派生的汇总胶囊,不对应任何 item。
  static String? _primaryKeyOf(_ChatRow row) => switch (row) {
    _SingleRow(item: final item) => item.key,
    _ToolGroupRow(tools: final tools) => tools.first.key,
    _ToolStatRow() => null,
  };

  void _syncComposerHeight() {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box?.size.height;
    if (height == null || !mounted) return;
    if ((height - _composerHeight).abs() < 0.5) return;
    setState(() => _composerHeight = height);
  }

  @override
  void dispose() {
    _railHideTimer?.cancel();
    _itemPositions.itemPositions.removeListener(_onPositions);
    _scrollProgress.dispose();
    _railVisible.dispose();
    _input.dispose();
    super.dispose();
  }

  /// 本来就贴着底就跟着新消息走;已经翻上去看历史了就别抢用户的位置。
  ///
  /// 判据换过三轮,前两轮都错:
  /// - 「maxScrollExtent - pixels < 240」:像素判据依赖估算的 maxScrollExtent,
  ///   流式期间那个值一直在抖;
  /// - 「最后一行的下标在可见集里」:一条长回答本身就能比视口高好几屏,用户
  ///   在它内部往上翻很远之后它**仍然**是最后一个可见行 —— 于是每个 token 都
  ///   判成「在底部」跳一次,视口被按回那一行顶部,人根本翻不上去。
  ///
  /// 现在看 [_tailPinned](终点哨兵可见不可见),那是可观测的事实而非推断。
  void _scrollToBottomIfNear() {
    if (!_itemScroll.isAttached || _rows.isEmpty) return;
    if (!_tailPinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScroll.isAttached || _rows.isEmpty) return;
      if (!_tailPinned) return;
      _jumpToBottom();
    });
  }

  /// 无条件跳到底部 —— 跳到**终点哨兵**并把它贴到视口底。
  ///
  /// 旧实现要「连推 6 帧、每帧朝当前 maxScrollExtent 再跳一次」,因为惰性列表
  /// 的 maxScrollExtent 是估算值、一次 jumpTo 到不了真正的底。按下标定位没有
  /// 这个问题,一步到位。
  ///
  /// 落点是哨兵而不是最后一行,因为 alignment 的语义是「把目标项的**前缘**
  /// 对齐到视口的这个比例位置」,拿最后一行做落点两个方向都不对:
  /// - alignment 0 = 那一行顶部贴视口顶。一条比视口高好几屏的长回答只会露出
  ///   开头,而且流式期间每个 token 都把视口按回它的顶部(向上抽动的由来)。
  /// - alignment 1 = 那一行前缘贴视口底,整行落到可见区**以下**,最后一条反而
  ///   看不见(实测:50 行 x 80px 跳最后一行,视口只到倒数第二行,那一行连
  ///   widget 树都没进;而且不会被夹回来 —— 算出的 offset 比 maxScrollExtent
  ///   小,夹取根本不触发)。
  ///
  /// 哨兵只有 1px:把它贴到视口底,就等于「内容的最末端刚好落在视口底」,
  /// 与最后一行有多高无关。
  ///
  /// 守卫放在这里而不是靠调用点自觉:列表空时槽位算出来可能是负的,
  /// `jumpTo(index: -1)` 会断言失败。按钮的 onJump 直接连到本方法。
  void _jumpToBottom() {
    if (!_itemScroll.isAttached || _rows.isEmpty) return;
    _tailPinned = true;
    _itemScroll.jumpTo(index: _terminalSlot, alignment: 1);
  }

  void _send({PiDelivery? delivery}) {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    unawaited(
      ref.read(piSessionNotifierProvider)?.sendPrompt(text, delivery: delivery),
    );
    _input.clear();
    setState(() => _inputText = '');
  }

  /// 中断当前生成再发送。桌面端的中断会把未发送的排队消息回填到电脑输入框,
  /// 这个副作用必须如实告知,不能藏。
  Future<void> _interruptAndSend() async {
    final desktop =
        ref.read(piSessionProvider).selectedSource?.isDesktop == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('中断当前生成?'),
        content: Text(
          desktop
              ? '会停止电脑端正在进行的这一轮,然后发送你的消息。\n'
                    '电脑端尚未发送的排队消息会被放回它的输入框。'
              : '会停止正在进行的这一轮,然后发送你的消息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('中断并发送'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _send(delivery: PiDelivery.interrupt);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      piSessionProvider.select((s) => s.revision),
      (_, _) => _scrollToBottomIfNear(),
    );

    final state = ref.watch(piSessionProvider);
    _syncDerived(state);
    final timestampFlags = _timestampFlagCache;

    // 会话/源一换就把落点打到最新消息。**不能在切换那一帧就跳** ——
    // 切换瞬间 items 往往还是空的(历史要等一个往返),那一帧跳了等于没跳,
    // 而且不会再有第二次机会。所以先记一个一次性 token,等这个会话真的有
    // 消息了再跳一次,然后立刻清掉。
    final sessionToken = '${state.selectedSourceId}/${state.sessionId}';
    if (sessionToken != _lastSessionToken) {
      _lastSessionToken = sessionToken;
      _pendingInitialBottomToken = sessionToken;
      _firstVisibleRow = 0;
      _scrollProgress.value = 0;
    }
    if (_pendingInitialBottomToken == sessionToken && state.items.isNotEmpty) {
      _pendingInitialBottomToken = null;
      // 已挂载的列表不会重读 initialScrollIndex,手动推一下。
      // 按下标定位一步到位,不需要旧那条「连推 6 帧朝 maxScrollExtent 逼近」的链。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_itemScroll.isAttached || _rows.isEmpty) return;
        _jumpToBottom();
      });
    }

    // 顶部只在「桥上还留着更早的历史」时占一个加载槽。本地不再窗口化。
    final hasEarlier = _hasEarlierSlot(state);
    _leadingSlots = hasEarlier ? 1 : 0;
    _trailingRequestSlots = state.pendingUiRequest != null ? 1 : 0;
    // 尾部两槽:输入卡占位 + 1px 终点哨兵。留白做成真实槽位才能观测「到底了」,
    // 见 _tailPinned。
    final itemCount =
        _leadingSlots + _rows.length + _trailingRequestSlots + _tailSlots;

    // 首帧之后量一次;之后由 SizeChangedLayoutNotifier 驱动
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncComposerHeight());
    // _composerHeight 已含手势条(Composer 内有 SafeArea),不要再加 bottomInset,
    // 否则列表底部悬空,和输入框之间露出空隙。
    final listBottomInset = _composerHeight + 4;

    return Column(
      children: [
        _LivenessBanner(state: state, topPadding: widget.topPadding),
        if (state.isCompacting) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          // 输入条**浮在**消息流之上,内容从它下面滚过去 —— 这才是「悬浮」。
          // 它原来是 Column 的兄弟节点,身后必然是 scaffold 的实色背景,
          // 所以无论怎么调都会看到一条白底。
          child: Stack(
            children: [
              if (!state.hasSession)
                const _NotConnectedView()
              else if (state.items.isEmpty)
                const _EmptyHint()
              else
                // 导航走左侧的 MessageNavRail(刻度=用户消息),
                // 系统 Scrollbar 撤掉 —— 两者功能重叠,双侧各一条太吵。
                //
                // 按**下标**定位而不是按像素:行高差几十倍时像素定位必然不准,
                // 而惰性列表的 maxScrollExtent 只是估算值。
                // 轨道显隐挂在**滚动起止**上而不是每次位置通知:后者一帧一次,
                // 每次都 cancel + new Timer,光这笔分配就在帧路径上白烧。
                NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollStartNotification) {
                      _showRail();
                    } else if (n is ScrollEndNotification) {
                      _scheduleRailHide();
                    }
                    return false;
                  },
                  child: ScrollablePositionedList.builder(
                  itemScrollController: _itemScroll,
                  itemPositionsListener: _itemPositions,
                  // 首帧落到终点哨兵上,alignment 1 把它贴到视口底 —— 哨兵只有
                  // 1px,贴底就等于「内容的最末端刚好在视口底」,不管最后一行
                  // 有多高都成立。
                  //
                  // 这里不能改成「最后一行 + alignment 0」:那是把那一行的**顶部**
                  // 对齐到视口顶,一条比视口高好几屏的长回答会只露出开头。
                  initialScrollIndex: itemCount == 0 ? 0 : itemCount - 1,
                  initialAlignment: 1,
                  // 底部留出输入卡的实测高度,免得最后一条消息被压在下面;
                  // 顶部留出灵动岛高度,静止时第一项在岛下面。
                  // 左右 4:卡片自己带 10 margin,总边距 14(收紧,放更多内容)。
                  // 底部不再用 padding 留白:它不是子项、拿不到可见性,
                  // 「到底了没有」就只能靠最后一行下标去猜(对高个流式行是错的)。
                  // 改成尾部两个真实槽位,见 _tailSlots。
                  padding: EdgeInsets.fromLTRB(4, widget.topPadding + 12, 4, 0),
                  // 长会话里 keep-alive 会把滚过的每一项都钉在内存里不释放,
                  // 越滚越重。消息项本身无状态可留(展开态在 ChatItem 上),关掉。
                  addAutomaticKeepAlives: false,
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    if (hasEarlier && index == 0) {
                      return _EarlierLoader(
                        loading: state.loadingEarlier,
                        onRetry: () => unawaited(_loadEarlier()),
                      );
                    }
                    // 终点哨兵:1px 的空盒子。它可见 = 真的到底了。
                    if (index == itemCount - 1) {
                      return const SizedBox(height: 1);
                    }
                    // 输入卡占位:把最后一条消息顶到输入卡上方。
                    if (index == itemCount - 2) {
                      return SizedBox(height: listBottomInset);
                    }
                    final full = index - _leadingSlots;
                    if (full >= _rows.length) {
                      final request = state.pendingUiRequest!;
                      return UiRequestCard(
                        key: ValueKey('ui-request-${request.id}'),
                        request: request,
                      );
                    }
                    final row = _rows[full];
                    final view = switch (row) {
                      _SingleRow(item: final item) => ChatItemView(
                        key: ValueKey(item.key),
                        item: item,
                      ),
                      // 工具卡也要各自封重绘边界:流式期间它们内部一直在变,
                      // 不隔离的话会拉着同屏其他卡一起重绘。
                      _ToolGroupRow(tools: final tools) => RepaintBoundary(
                        // key 用首个工具的 key:streaming 中新工具入组时
                        // key 稳定,widget 复用只是 tools 变长。
                        key: ValueKey(tools.first.key),
                        child: ToolGroupCard(tools: tools),
                      ),
                      // 统计行无 key:它不属于任何 item,也无状态可保。
                      _ToolStatRow(tools: final tools) => RepaintBoundary(
                        child: ToolGroupCard(tools: tools, statOnly: true),
                      ),
                    };
                    if (!timestampFlags[full]) return view;
                    // 时间戳只会挂在有时间的行(user/assistant);
                    // 工具组行无时间,flag 一定是 false,走不到这里。
                    final rowTime = switch (row) {
                      _SingleRow(item: final item) => timeOf(item),
                      _ToolGroupRow() || _ToolStatRow() => null,
                    };
                    if (rowTime == null) return view;
                    return Column(
                      // 默认 center 会给子项松散宽度:用户气泡收缩成内容宽
                      // 再被居中,短消息就「跑到屏幕中间」了。stretch 保持
                      // 满宽紧约束,右对齐交给气泡自己;时间戳自带 Center,
                      // 不受影响。
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        MessageTimestamp(time: rowTime),
                        view,
                      ],
                    );
                    },
                  ),
                ),
              if (state.hasSession)
                Positioned(
                  right: 16,
                  // 抬到输入卡上方,不然会被它压住
                  bottom: listBottomInset,
                  child: ScrollToBottomButton(
                    positions: _itemPositions,
                    terminalSlot: itemCount - 1,
                    onJump: _jumpToBottom,
                    revision: state.revision,
                  ),
                ),
              // 消息导航轨道:刻度=用户消息,滚动时左侧弹出。
              if (state.hasSession && _navAnchors.length >= 2)
                Positioned(
                  left: 0,
                  top: widget.topPadding + 32,
                  bottom: listBottomInset + 24,
                  // 显隐走 ValueListenableBuilder 而不是 setState:滚动一停一动都
                  // 重建整个 ChatBody 的话,会连带重建所有可见消息卡(markdown 解析 +
                  // 语法高亮),那是卡顿的一大头。
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _railVisible,
                    builder: (context, visible, _) => MessageNavRail(
                      visible: visible || _railInteracting,
                      anchors: _navAnchors,
                      progress: _scrollProgress,
                      onJump: _jumpToRow,
                      onInteractionChanged: (interacting) {
                        _railInteracting = interacting;
                        if (interacting) {
                          _railHideTimer?.cancel();
                        } else {
                          _scheduleRailHide();
                        }
                      },
                    ),
                  ),
                ),
              // 顶部渐变遮罩:灵动岛不遮一整栏,内容滚到顶部时渐隐。
              // 上段纯不透明(盖住岛后面的碎片),下段渐隐到透明。
              if (widget.topPadding > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: widget.topPadding + 24,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Theme.of(context).colorScheme.surface,
                            Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0),
                          ],
                          stops: const [0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              // 渐变遮罩:紧贴输入卡顶部(_composerHeight 已含手势条,
              // 不要再加 bottomInset,否则渐变悬空、和输入卡之间露出空隙)。
              // 高度 14:28 的渐隐带太抢,文字还没滚到输入卡就化没了。
              Positioned(
                left: 0,
                right: 0,
                bottom: _composerHeight,
                height: 14,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0),
                          Theme.of(context).colorScheme.surface,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 输入永远开放:任意一端、任意时刻都能发消息和打断。
              // 唯一的门是"还没连上 bridge",那时整个界面都不在这条分支。
              // 外层包一层不透明背景:确保输入框下方(含手势条区域)没有文字透出。
              // 参考 Claude Code:输入框下方是一块不透明底色,列表内容不会透出。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Theme.of(context).colorScheme.surface,
                  child: NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _syncComposerHeight(),
                      );
                      return true;
                    },
                    child: SizeChangedLayoutNotifier(
                      key: _composerKey,
                      child: Composer(
                        controller: _input,
                        enabled: true,
                        streaming: state.isStreaming,
                        compacting: state.isCompacting,
                        onSend: _send,
                        onSteer: () => _send(delivery: PiDelivery.steer),
                        onFollowUp: () => _send(delivery: PiDelivery.followUp),
                        onInterruptAndSend: _interruptAndSend,
                        onAbort: () => unawaited(
                          ref.read(piSessionNotifierProvider)?.abort(),
                        ),
                        onChanged: (text) => setState(() => _inputText = text),
                        quickPanel: QuickPanel(
                          inputText: _inputText,
                          onInsert: (text) {
                            _input.text = text;
                            _input.selection = TextSelection.collapsed(
                              offset: text.length,
                            );
                            setState(() => _inputText = text);
                          },
                          onSendPrompt: (text) {
                            // 快捷指令没有输入框可清,自己挡住连点
                            if (_sending) return;
                            setState(() => _sending = true);
                            unawaited(
                              ref
                                  .read(piSessionNotifierProvider)
                                  ?.sendPrompt(text)
                                  .whenComplete(() {
                                    if (mounted) {
                                      setState(() => _sending = false);
                                    }
                                  }),
                            );
                          },
                        ),
                      ),
                    ),
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

class _NotConnectedView extends ConsumerWidget {
  const _NotConnectedView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(piSessionProvider.select((s) => s.status));
    final error = ref.watch(piSessionProvider.select((s) => s.error));
    final hasDevices = ref.watch(
      deviceManagerProvider.select((s) => s.devices.isNotEmpty),
    );
    final colors = Theme.of(context).colorScheme;

    // 空状态用场景插画而不是图标 —— 设计规范要的「安静等待」气质:
    // 「中央留白插画 + 标题 + 副文案 + 稳重主按钮」。
    final (message, hint) = switch (status) {
      PiConnStatus.connecting => ('正在连接…', '正在唤醒你的电脑。'),
      PiConnStatus.failed => ('连接失败', '请在设备页检查 bridge 地址和 token。'),
      _ => ('尚未连接', '添加一台设备,开始远程协作。'),
    };

    // Center 包 SCSV:内容矮时居中,内容比视口高时(横屏/大字体/长错误
    // 文本)可以滚 —— 否则 Column 在 Stack 的定高里没有出路,直接纵向溢出。
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 矢量装饰:素材 PNG 自带象牙纸底,在奶油页面上会露出一圈更亮的
              // 白边(看着像廉价贴图)。CustomPaint 天然透明,干净。
              const EditorialOrnament(size: 156),
              const SizedBox(height: 26),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 27, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: AppType.serifItalic(color: colors.onSurfaceVariant),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.error),
                ),
              ],
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (status != PiConnStatus.connecting && hasDevices)
                    FilledButton.icon(
                      onPressed: () => unawaited(
                        ref
                            .read(deviceManagerProvider.notifier)
                            .connectActiveDevice(),
                      ),
                      icon: const Icon(Icons.link),
                      label: const Text('连接'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DevicesPage(),
                      ),
                    ),
                    icon: const Icon(Icons.devices_outlined),
                    label: const Text('管理设备'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话活跃度横幅。
///
/// **空闲且一切正常时完全不渲染** —— 这是"大方"最直接的动作:平时聊天区域
/// 上方没有任何 chrome。只有四种真正需要说话的情况才出现。
class _LivenessBanner extends ConsumerWidget {
  const _LivenessBanner({required this.state, this.topPadding = 0});

  final PiState state;

  /// 灵动岛占位:横幅显示时要在岛下面,不被遮住。
  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final source = state.selectedSource;

    final queueParts = <String>[
      if (state.steeringQueue.isNotEmpty) '插队 ${state.steeringQueue.length}',
      if (state.followUpQueue.isNotEmpty) '排队 ${state.followUpQueue.length}',
    ];

    final (
      IconData icon,
      String text,
      Color bg,
      Color fg,
      Widget? action,
    ) = switch (state) {
      _ when source == null => (
        Icons.dashboard_customize_outlined,
        '还没有选择会话',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        TextButton(
          // maybeOf:ChatBody 被单独 pump 时(测试)没有外层 Scaffold,
          // 用 of() 会直接抛异常。
          onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
          child: const Text('选择会话'),
        ),
      ),
      _ when state.sessionWaking => (
        Icons.play_circle_outline,
        '正在唤醒 ${source.label}',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      // 「正在生成」**不占横幅**。这个状态本来就有三处更省地方的表达:
      // 顶栏的中断按钮、助手气泡里的打字指示器、输入框的「生成中 · 发送会插队」。
      // 再压一条 50dp 的横幅纯属浪费空间。
      //
      // 压缩不一样:它没有打字指示器、没有中断按钮,输入框也不知道自己在忙,
      // 以前只有一条 2px 进度条 —— 等于没提示。所以压缩要占横幅。
      _ when state.isCompacting => (
        Icons.compress,
        '${source.label} 正在压缩上下文 · 消息会排队等它完成',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      _ when !source.connected => (
        Icons.bedtime_outlined,
        '${source.label} 已休眠 · 发消息会自动唤醒',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      // 一切正常:下面 text.isEmpty 会返回 SizedBox.shrink(),这里的颜色画不出来
      _ => (
        Icons.circle,
        '',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
    };

    // 一切正常:不渲染任何东西
    if (text.isEmpty && queueParts.isEmpty) return const SizedBox.shrink();

    return Card(
      // 14 = ListView 左右 padding(4) + 卡片 margin(10),和内容卡对齐。
      margin: EdgeInsets.fromLTRB(14, topPadding + 10, 14, 2),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty)
              Row(
                children: [
                  if (state.isStreaming || state.isCompacting)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                      ),
                    )
                  else
                    Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: fg),
                    ),
                  ),
                  ?action,
                ],
              ),
            if (queueParts.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: text.isEmpty ? 0 : 4),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: fg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${queueParts.join(' · ')} — '
                        '${[...state.steeringQueue, ...state.followUpQueue].first}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 消息列表的渲染行:由 ChatItem 列表派生。
///
/// 每个 ToolItem 各自一行([_ToolGroupRow] 现在只装单个工具),其余每项一行;
/// 每轮末尾追加一颗纯统计的 [_ToolStatRow]。下标/时间戳全按行维度计算,
/// 不再直接用 items 下标。
sealed class _ChatRow {
  const _ChatRow();
}

class _SingleRow extends _ChatRow {
  const _SingleRow(this.item);
  final ChatItem item;
}

class _ToolGroupRow extends _ChatRow {
  const _ToolGroupRow(this.tools);
  final List<ToolItem> tools;
}

class _ToolStatRow extends _ChatRow {
  const _ToolStatRow(this.tools);
  final List<ToolItem> tools;
}

/// 列表顶部的历史加载指示。
///
/// 不是按钮:滚到顶部附近由 `_onPositions` 自动触发补齐。仍然可点只是兼一手
/// —— 内容没撑满一屏时根本没有滚动事件,此时自动触发依赖不上。
///
/// 不再显示「还剩 N 条」:那个数是「尾部窗口之上还没渲染的本地条数」,
/// 而窗口化已经拆掉了(它是位置乱窜的根因)。现在未加载的历史全在桥上,
/// 条数不在本地,数不出来。
class _EarlierLoader extends StatelessWidget {
  const _EarlierLoader({required this.onRetry, this.loading = false});

  final VoidCallback onRetry;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: InkWell(
          onTap: loading ? null : onRetry,
          borderRadius: BorderRadius.circular(PiShape.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Text('正在加载更早的消息…', style: text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EditorialOrnament(size: 150),
              const SizedBox(height: 26),
              Text(
                '开始一段对话',
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 27, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                '开始你的第一个指令',
                textAlign: TextAlign.center,
                style: AppType.serifItalic(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              // 页脚一条编辑式短线,替代原来那枚带白底的印章 PNG
              SizedBox(
                width: 56,
                child: EditorialRule(color: colors.outlineVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
