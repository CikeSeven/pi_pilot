/// 事件定序的纯逻辑,便于单测(notifier 只负责调用与副作用)。
library;

enum SourceApply {
  /// 正好接在已应用序列之后,直接应用。
  apply,

  /// 已经应用过,丢弃。
  duplicate,

  /// 不是当前选中的 source,忽略。
  wrongSource,

  /// epoch 变了,整段历史作废,必须重新同步。
  epochChanged,

  /// 中间缺了若干条(重放环溢出)。采纳新序号并在后台补齐,
  /// 而不是永久拒绝——后者会让客户端彻底卡死。
  gap,
}

class SourceCursor {
  const SourceCursor({this.sourceId, this.epoch, this.seq = 0});

  final String? sourceId;
  final String? epoch;
  final int seq;

  SourceApply classify({
    required String? sourceId,
    required String? epoch,
    required int? seq,
  }) {
    if (sourceId == null || epoch == null || seq == null) {
      return SourceApply.wrongSource;
    }
    if (this.sourceId != null && sourceId != this.sourceId) {
      return SourceApply.wrongSource;
    }
    if (this.epoch != null && epoch != this.epoch) {
      return SourceApply.epochChanged;
    }
    if (seq <= this.seq) return SourceApply.duplicate;
    if (seq != this.seq + 1) return SourceApply.gap;
    return SourceApply.apply;
  }

  /// 采纳一个序号(应用或跨越断层后)。
  SourceCursor adopt({
    required String sourceId,
    required String epoch,
    required int seq,
  }) => SourceCursor(sourceId: sourceId, epoch: epoch, seq: seq);

  SourceCursor reset({String? sourceId, String? epoch, int seq = 0}) =>
      SourceCursor(sourceId: sourceId, epoch: epoch, seq: seq);
}
