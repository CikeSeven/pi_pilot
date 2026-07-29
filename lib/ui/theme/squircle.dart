import 'dart:math' as math;
import 'package:flutter/material.dart';

/// **Squircle**（超椭圆连续曲率圆角）。
///
/// 标准圆角（`BorderRadius.circular`）在直线和圆弧的连接处有**曲率突变**--
/// 曲率从 0（直线）瞬间跳到 1/r（圆弧），放大看有一个"折角"。
///
/// Squircle 用超椭圆方程 `|x|ⁿ + |y|ⁿ = rⁿ` 让曲率**连续过渡**:
/// 直线到弧线平滑渐变,没有突变点。这就是苹果圆角看着"更柔"的原因。
///
/// API 与 `RoundedRectangleBorder` 兼容(同样传 `borderRadius` + `side`),
/// 可以直接替换。
///
/// ## smoothing 参数
///
/// - `n=2`:纯椭圆(最圆)
/// - `n=4~5`:接近苹果圆角(**默认 5**)
/// - `n=∞`:矩形(无圆角)
///
/// 每角采样 12 个点,在手机分辨率下看不出折线,路径只算一次(不每帧算)。
class SquircleBorder extends OutlinedBorder {
  const SquircleBorder({
    this.borderRadius = BorderRadius.zero,
    super.side,
    this.smoothing = 5.0,
  });

  final BorderRadius borderRadius;

  /// 超椭圆指数 n。越大越方,越小越圆。
  final double smoothing;

  @override
  ShapeBorder scale(double t) => SquircleBorder(
    borderRadius: borderRadius * t,
    side: side.scale(t),
    smoothing: smoothing,
  );

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    // 描边很细(1px),inner path 只需把 rect 缩一点,radius 不变(差异忽略)。
    return _buildPath(rect.deflate(side.width / 2), borderRadius);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return _buildPath(rect, borderRadius);
  }

  /// 中心是超椭圆角中心,从 startAngle 顺时针到 endAngle 采样点。
  ///
  /// Flutter 坐标 y 向下,顺时针走:
  /// - a=0:   (r, 0)  东
  /// - a=π/2: (0, r)  南
  /// - a=π:   (-r, 0) 西
  /// - a=3π/2:(0,-r)  北
  void _corner(
    Path path,
    Offset center,
    double r,
    double startAngle,
    double endAngle,
    int steps,
  ) {
    final n = smoothing;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final a = startAngle + (endAngle - startAngle) * t;
      final cosA = math.cos(a);
      final sinA = math.sin(a);
      // 超椭圆:x = r * sign(cos) * |cos|^(2/n)
      final px = center.dx +
          r * (cosA < 0 ? -1.0 : 1.0) *
              math.pow(cosA.abs(), 2 / n).toDouble();
      final py = center.dy +
          r * (sinA < 0 ? -1.0 : 1.0) *
              math.pow(sinA.abs(), 2 / n).toDouble();
      path.lineTo(px, py);
    }
  }

  Path _buildPath(Rect rect, BorderRadius radius) {
    final path = Path();
    final l = rect.left;
    final t = rect.top;
    final r = rect.right;
    final b = rect.bottom;

    // 四角半径(钳制到不超尺寸)。
    final maxR = math.min(rect.width, rect.height) / 2;
    final rTL = radius.topLeft.x.clamp(0.0, maxR);
    final rTR = radius.topRight.x.clamp(0.0, maxR);
    final rBR = radius.bottomRight.x.clamp(0.0, maxR);
    final rBL = radius.bottomLeft.x.clamp(0.0, maxR);

    const steps = 12;

    // 顺时针:起点 = 顶边左端(左上角退出点)
    path.moveTo(l + rTL, t);
    // 顶边
    path.lineTo(r - rTR, t);
    // 右上角:北(3π/2) -> 东(0 = 2π)
    _corner(path, Offset(r - rTR, t + rTR), rTR, 3 * math.pi / 2, 2 * math.pi, steps);
    // 右边
    path.lineTo(r, b - rBR);
    // 右下角:东(0) -> 南(π/2)
    _corner(path, Offset(r - rBR, b - rBR), rBR, 0, math.pi / 2, steps);
    // 底边
    path.lineTo(l + rBL, b);
    // 左下角:南(π/2) -> 西(π)
    _corner(path, Offset(l + rBL, b - rBL), rBL, math.pi / 2, math.pi, steps);
    // 左边
    path.lineTo(l, t + rTL);
    // 左上角:西(π) -> 北(3π/2)
    _corner(path, Offset(l + rTL, t + rTL), rTL, math.pi, 3 * math.pi / 2, steps);
    path.close();
    return path;
  }

  @override
  SquircleBorder copyWith({
    BorderRadius? borderRadius,
    BorderSide? side,
    double? smoothing,
  }) {
    return SquircleBorder(
      borderRadius: borderRadius ?? this.borderRadius,
      side: side ?? this.side,
      smoothing: smoothing ?? this.smoothing,
    );
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side == BorderSide.none) return;
    final path = getOuterPath(rect, textDirection: textDirection);
    canvas.drawPath(path, side.toPaint());
  }

  @override
  bool operator ==(Object other) =>
      other is SquircleBorder &&
      other.borderRadius == borderRadius &&
      other.side == side &&
      other.smoothing == smoothing;

  @override
  int get hashCode => Object.hash(borderRadius, side, smoothing);
}
