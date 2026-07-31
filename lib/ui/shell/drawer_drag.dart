import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 抽屉拖动手势识别器:**同一根手指全程由抽屉持有,右滑拉开、左滑推回**。
///
/// 为什么要自己写而不用 `Scaffold.drawer` 那套:
///
/// 手势竞技场(gesture arena)的胜负在手势**开始阶段**就决出了。原来的做法是
/// 监听 `PageView` 的前缘过卷,累计够 64px 就调 `openDrawer()` —— 但那只是
/// 播一段 fling 动画,这根手指早已被 `PageView` 的横向 drag 识别器赢走。于是
/// 用户不松手继续左滑,位移全部喂给 `PageView`,变成翻页去「设备」。
///
/// 中途补救也不成立:切 `PageView.physics`、动态放宽 `drawerEdgeDragWidth`、
/// 或事后 `openDrawer()`,都无法把**已在飞的** pointer 转交给另一个识别器 ——
/// 放宽拖动区只影响之后新建的识别器。
///
/// 所以正确做法是从一开始就参与竞争:本识别器挂在 `PageView` **页面内部**
/// (作为其后代),按方向自己决定去留 ——
/// - 抽屉关着:横向位移超过 slop 后看方向。**向左立刻 reject**,把手势让给
///   `PageView` 翻页;**向右才 accept**,开始拉开抽屉。
/// - 抽屉已开、或本次手势已被 accept:左右两个方向都由它持有,`PageView`
///   拿不到这根手指。于是同一根手指反向左滑时,进度连续从 1 降到 0。
/// - 竖向为主的位移一律 reject,交给聊天列表滚动。
class DrawerDragRecognizer extends OneSequenceGestureRecognizer {
  DrawerDragRecognizer({
    required this.isOpen,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
    super.debugOwner,
  });

  /// 抽屉当前是否已经打开(哪怕只开了一部分)。
  ///
  /// 已开时不再做方向筛选:两个方向都归抽屉,否则左滑关到一半又往右推
  /// 就会被 `PageView` 夺走手势。
  final ValueGetter<bool> isOpen;

  final VoidCallback onStart;

  /// 横向位移增量(像素,向右为正)。
  final ValueChanged<double> onDelta;

  /// 手势结束:带横向速度(像素/秒,向右为正),用来决定落到全开还是全关。
  final ValueChanged<double> onEnd;

  /// 判定横向意图前要累计的位移。
  ///
  /// **必须小于 `kTouchSlop`(18px)**。`PageView` 的横向 drag 识别器到 18px
  /// 就向竞技场宣布胜利,谁先表态谁拿走这根 pointer。早先这里用 `kPanSlop`
  /// (36px):真机上手指每帧只挪 5~20px,走到 18px 时手势已经归 `PageView`,
  /// 永远等不到 36px —— 右滑完全打不开抽屉。
  ///
  /// (当时的测试一步就走 50px,首个 move 事件直接越线侥幸赢下,把这个 bug
  /// 整整掩过去了。所以下面的回归测试一律按真机节奏分小步走。)
  ///
  /// 取 8px:既赶在 `PageView` 之前表态,又足以过滤指尖落下时的抖动。
  /// 提前宣布是安全的 —— 对话页右侧没有页面,向右滑本来也只会回弹。
  static const double _slop = 8.0;

  /// 竖向让位的阈值。列表滚动用的是系统 touch slop,比横向判定宽松一点,
  /// 确保「想滚列表」不会被误判成开抽屉。
  static const double _verticalSlop = kTouchSlop;

  Offset _accum = Offset.zero;
  bool _accepted = false;
  VelocityTracker? _velocity;

  @override
  String get debugDescription => 'drawer drag';

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _accum = Offset.zero;
    _accepted = false;
    _velocity = VelocityTracker.withKind(event.kind);
    startTrackingPointer(event.pointer, event.transform);
    // 抽屉已经开着:这根手指从落下就归抽屉,不必等方向判定。
    // 遮罩上的横向滑动要能直接把抽屉推回去。
    if (isOpen()) {
      _accepted = true;
      onStart();
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    _velocity?.addPosition(event.timeStamp, event.localPosition);

    if (event is PointerMoveEvent) {
      if (_accepted) {
        onDelta(event.delta.dx);
        return;
      }
      _accum += event.delta;
      // 竖向为主:这是在滚聊天列表,让给它。
      if (_accum.dy.abs() > _verticalSlop &&
          _accum.dy.abs() > _accum.dx.abs()) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        return;
      }
      if (_accum.dx.abs() < _slop) return;
      if (_accum.dx > 0) {
        // 向右:开抽屉的意图,接管这根手指。
        _accepted = true;
        onStart();
        resolve(GestureDisposition.accepted);
        // slop 期间攒下的位移不能丢,否则抽屉起手会「跳一下」才跟上手指。
        onDelta(_accum.dx);
      } else {
        // 向左且抽屉关着:那是翻页,让给 PageView。
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
      }
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_accepted) {
        final velocity = _velocity?.getVelocity().pixelsPerSecond.dx ?? 0;
        onEnd(velocity);
      }
      stopTrackingPointer(event.pointer);
      _accepted = false;
    }
  }

  /// 竞技场判我们赢(可能是别人退出后默认胜出)。
  ///
  /// **不能在这里兼职「开始跟手」**。微小位移或单纯点击时,横向意图还没
  /// 判定出来,PageView 那边也因为不够 slop 而放弃 —— 竞技场于是把胜利
  /// 默认判给唯一剩下的我们。早年这里写了“既然拿到手势就开始跟手”的兜底,
  /// 结果轻轻一点屏幕、松手后抽屉就自己弹开了。
  ///
  /// 所以只认 [handleEvent] 里真正判定过向右意图(或抽屉已开)那一条路径;
  /// 被动获胜一律不做事。
  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    stopTrackingPointer(pointer);
    _accepted = false;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
}
