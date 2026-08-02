/// 消息导航轨道的锚点:一条用户消息在完整行表中的位置与预览。
///
/// 单独成文件是为了让锚点数学([chat_scroll_anchor.dart])不必依赖 UI widget
/// —— 那些换算要能在纯 Dart 测试里跑,不该拖进一整个 Flutter widget 树。
class NavAnchor {
  const NavAnchor({required this.rowIndex, required this.preview, this.time});

  /// 该用户消息在完整渲染行表(_rows)中的下标。
  final int rowIndex;

  /// 消息全文(预览卡自己截断)。
  final String preview;
  final DateTime? time;
}
