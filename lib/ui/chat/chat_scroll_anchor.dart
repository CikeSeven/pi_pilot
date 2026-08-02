/// 消息列表的滚动锚点数学。
///
/// 单独成文件是因为这几处换算一旦算错就是**用户可见的乱窜**,而内联在
/// 私有 State 里没法单独测:
/// - 头部插入历史后视口该落在哪(按稳定主键锚定,不是按估算 extent 补偿);
/// - 左侧导航轨道的手势位置 ↔ 用户消息锚点的双向映射。
///
/// 旧实现全部建立在 `pixels / maxScrollExtent` 比例 +「行高均等」的假设上。
/// 聊天行高差几十倍(一条用户消息 vs 一个大 bash 输出井),而惰性列表的
/// `maxScrollExtent` 本身又只是按已建行平均高度外推的估算值 —— 那套假设
/// 从根上不成立,所以这里改成**纯下标/主键运算**,和行高彻底解耦。
library;

import 'nav_anchor.dart';

/// 视口锚:插入历史之前记下的「当前屏内第一条内容行」。
///
/// 用 [rowKey] 而不是行下标,是因为行表是从 items 派生的 —— 一次同步里工具行/
/// 统计行的数量都可能变,「旧下标 + 插入行数」推算出来的位置不可信。主键是
/// 唯一可信的身份。
///
/// [leadingEdge] 是该行前缘在视口里的归一化位置。必须一起记下来:只复原下标
/// 会把那一行强行对齐到视口顶,视觉上跳一下。
///
/// **约束**:[leadingEdge] 只接受 0~1。`ItemScrollController.jumpTo` 的
/// alignment 是视口对齐值,喂负数不成立;所以采样时要挑屏内的行,而不是下标
/// 最小的那一项(它通常已经有一部分滚到视口上方去了)。
class ViewportAnchor {
  const ViewportAnchor({required this.rowKey, required this.leadingEdge});

  /// 该行的稳定主键(单行 = item key,工具行 = 首个工具的 key)。
  final String rowKey;

  /// 该行前缘在视口里的归一化位置(0 = 贴视口顶,1 = 贴视口底)。
  final double leadingEdge;
}

/// 头部插入历史之后,原锚点行的新下标。
///
/// [rowIndexByKey] 是插入后新行表的「主键 → 下标」映射。查不到返回 null ——
/// 那说明这一行被压缩/替换掉了,此时硬跳反而更乱,调用方应当不动为上。
int? restoredRowIndex(ViewportAnchor anchor, Map<String, int> rowIndexByKey) =>
    rowIndexByKey[anchor.rowKey];

/// 轨道手势位置(0~1) → 锚点序号。
///
/// 轨道刻度是**均匀密布**的,第 i 个刻度就是第 i 条用户消息,和消息实际
/// 占多少像素无关 —— 所以这里只按序号均分,不掺任何高度信息。
int anchorIndexAt(double t, int count) {
  if (count <= 0) return 0;
  final clamped = t.clamp(0.0, 1.0);
  return (clamped * (count - 1)).round().clamp(0, count - 1);
}

/// 当前可见行 → 轨道焦点位置(0~1)。
///
/// 语义是「视口正在看第 i 条用户消息,焦点就严格落在第 i 个大节点上」,
/// 两条消息之间按行号线性插值保持连续。
///
/// 用**二分**定位所在区间:滚动时每帧都要算一次,长会话里锚点上千,
/// 线性扫描是白烧帧时间(旧实现就是线性的)。
double anchorFocusOf(List<NavAnchor> anchors, int visibleRow) {
  final n = anchors.length;
  if (n == 0) return 0;
  if (n == 1) return 0;
  if (visibleRow <= anchors.first.rowIndex) return 0;
  if (visibleRow >= anchors.last.rowIndex) return 1;

  // 找最后一个 rowIndex <= visibleRow 的锚点。
  var lo = 0;
  var hi = n - 1;
  while (lo + 1 < hi) {
    final mid = (lo + hi) >> 1;
    if (anchors[mid].rowIndex <= visibleRow) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = anchors[lo].rowIndex;
  final b = anchors[lo + 1].rowIndex;
  final local = b == a
      ? 0.0
      : ((visibleRow - a) / (b - a)).clamp(0.0, 1.0).toDouble();
  return ((lo + local) / (n - 1)).clamp(0.0, 1.0);
}
