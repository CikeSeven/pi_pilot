import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';
import '../../common/tokens.dart';
import 'assistant_bubble.dart';
import 'bash_card.dart';
import 'custom_item_view.dart';
import 'message_timestamp.dart';
import 'system_notice.dart';
import 'tool_card.dart';
import 'user_bubble.dart';

/// Renders a single [ChatItem] in the conversation list.
class ChatItemView extends StatelessWidget {
  const ChatItemView({super.key, required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: _Entrance(
        item: item,
        child: switch (item) {
          UserItem i => UserBubble(item: i),
          AssistantItem i => AssistantBubble(item: i),
          ToolItem i => ToolCard(item: i),
          BashItem i => BashCard(item: i),
          SystemItem i => SystemNotice(item: i),
          CustomItem i => CustomItemView(item: i),
          SummaryItem i => SummaryItemView(item: i),
        },
      ),
    );
  }
}

/// 新消息入场动画(淡入 + 6px 上滑)。
/// initState 一次性判定:仅时间戳距现在 <1s 的消息播放——
/// 历史加载、滚动复用、流式重建都不动画。
class _Entrance extends StatefulWidget {
  const _Entrance({required this.item, required this.child});

  final ChatItem item;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> {
  late final bool _animate;

  @override
  void initState() {
    super.initState();
    final time = timeOf(widget.item);
    _animate =
        time != null &&
        DateTime.now().difference(time).abs() < const Duration(seconds: 1);
  }

  @override
  Widget build(BuildContext context) {
    if (!_animate) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: PiMotion.entrance,
      curve: PiMotion.enter,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - t)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
