import 'package:flutter/material.dart';

import '../../../state/pi_session.dart';

/// 取聊天项的时间戳(工具/系统项无时间)。
DateTime? timeOf(ChatItem item) => switch (item) {
  UserItem i => i.time,
  AssistantItem i => i.time,
  _ => null,
};

/// 与上一条带时间的消息间隔超过 5 分钟才显示时间。
bool shouldShowTimestamp(DateTime? prev, DateTime? current) {
  if (current == null) return false;
  if (prev == null) return true;
  return current.difference(prev).abs() > const Duration(minutes: 5);
}

String formatTimeShort(DateTime time) {
  final local = time.toLocal();
  String pad(int v) => v.toString().padLeft(2, '0');
  return '${pad(local.hour)}:${pad(local.minute)}';
}

String formatTimeFull(DateTime time) {
  final local = time.toLocal();
  String pad(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
}

/// 居中的小号时间标注。
class MessageTimestamp extends StatelessWidget {
  const MessageTimestamp({super.key, required this.time});

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          formatTimeShort(time),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}
