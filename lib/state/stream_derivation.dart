import 'pi_session.dart';

/// 流式状态的派生:任一证据成立即视为正在生成。
///
/// 单独依赖快照里的 `isStreaming` 是不够的——桌面 relay 在流式期间
/// 拿到的快照可能是上一轮结束时的(那时 `ctx.isIdle()` 为真),
/// 而 `agent_start` 事件又可能被重放环挤掉。
bool deriveStreaming({
  required bool snapshotStreaming,
  required bool eventStreaming,
  required bool hasOpenAssistantBubble,
  required bool hasInFlightMessage,
}) {
  return snapshotStreaming ||
      eventStreaming ||
      hasOpenAssistantBubble ||
      hasInFlightMessage;
}

/// 「撤销上一轮」的目标 = 当前分支最后一条带 entryId 的用户消息。
String? undoTarget(List<ChatItem> items) {
  for (final item in items.reversed) {
    if (item is UserItem && item.entryId != null) return item.entryId;
  }
  return null;
}
