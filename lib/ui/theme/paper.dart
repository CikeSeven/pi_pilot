import 'dart:math' as math;

import 'package:flutter/material.dart';


/// 素材包资源路径常量。集中一处,避免字符串散落各屏。
abstract final class PiAsset {
  static const _img = 'assets/images';

  // 背景。浅色统一一张、深色统一一张(见 BackdropPaper)。
  // 之前按页面分了三张浅色底图,反而让切换有割裂感;统一一张更顺。
  static const bgCreamMain = '$_img/bg_cream_main.png';   // 浅色统一底
  static const bgCharcoal = '$_img/bg_charcoal.png';      // 深色统一底
  // 旧的分页底图保留常量但不再使用,避免引用断裂。
  static const bgCreamPaper = '$_img/bg_cream_paper.png';
  static const bgIvoryLinework = '$_img/bg_ivory_linework.png';
  static const bgBlushAccent = '$_img/bg_blush_accent.png';
  static const bgOliveCream = '$_img/bg_olive_cream.png';
  static const bgTerracottaGrain = '$_img/bg_terracotta_grain.png';

  // 场景插画
  static const illoDeskSetup = '$_img/illo_desk_setup.png';
  static const illoWindowMoment = '$_img/illo_window_moment.png';
  static const illoConnectDevice = '$_img/illo_connect_device.png';
  static const illoRemoteControl = '$_img/illo_remote_control.png';
  static const illoQuietStudy = '$_img/illo_quiet_study.png';
  static const illoAiHelper = '$_img/illo_ai_helper.png';
  static const illoBooksNotes = '$_img/illo_books_notes.png';
  static const illoPoeticBust = '$_img/illo_poetic_bust.png';

  // 纹样装饰
  static const decoWaveform = '$_img/deco_waveform.png';
  static const decoPaperFiber = '$_img/deco_paper_fiber.png';
  static const decoGrain = '$_img/deco_grain.png';
  static const decoDivider = '$_img/deco_divider.png';
  static const decoLeafyBranch = '$_img/deco_leafy_branch.png';
  static const decoCircleSeal = '$_img/deco_circle_seal.png';
  static const decoMiniStars = '$_img/deco_mini_stars.png';
  static const decoDottedGrid = '$_img/deco_dotted_grid.png';
  static const decoArcLine = '$_img/deco_arc_line.png';

  // 品牌
  static const brandWordmark = '$_img/brand_wordmark.png';
  static const brandSparkle = '$_img/brand_sparkle.png';
  static const brandSeal = '$_img/brand_seal.png';
  static const brandLeafyCorner = '$_img/brand_leafy_corner.png';

  // 徽章
  static const badgePiSeal = '$_img/badge_pi_seal.png';
  static const badgeStatusOk = '$_img/badge_status_ok.png';
  static const badgeInProgress = '$_img/badge_in_progress.png';
  static const badgeRemote = '$_img/badge_remote.png';
  static const badgeSync = '$_img/badge_sync.png';
}

/// 纸感背景:在页面底色之上叠一层极淡的纤维/颗粒纹理。
///
/// 为什么不直接把 2MB 的背景图铺满:
/// - 那张图自带自己的色调,会和主题色(六种 accent + 深浅两套)打架;
/// - 滚动时大图重采样有开销。
///
/// 这里的做法是**底色由主题给、纹理只做叠加**:
/// `colorScheme.surface` 铺底 → 纹理图以极低不透明度 + `repeat` 平铺覆盖。
/// 这样任何主题下都是「同一张纸」,只是纸的颜色跟着主题走。
class PaperBackground extends StatelessWidget {
  const PaperBackground({
    super.key,
    required this.child,
    this.color,
    this.grainOpacity,
    this.showGrain = true,
  });

  final Widget child;

  /// 底色。默认 `colorScheme.surface`。
  final Color? color;

  /// 纹理不透明度。默认浅色 0.035 / 深色 0.05——
  /// 再高就从「纸感」变成「脏」。
  final double? grainOpacity;

  final bool showGrain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final base = color ?? theme.colorScheme.surface;
    final opacity = grainOpacity ?? (isDark ? 0.05 : 0.035);

    return DecoratedBox(
      decoration: BoxDecoration(color: base),
      child: showGrain
          ? Stack(
              fit: StackFit.passthrough,
              children: [
                // 纹理层:不拦截手势,不参与语义树。
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: opacity,
                      child: Image.asset(
                        PiAsset.decoPaperFiber,
                        repeat: ImageRepeat.repeat,
                        // 深色纸上纹理要提亮才看得见,浅色纸上要压暗。
                        color: isDark ? Colors.white : Colors.black,
                        colorBlendMode: BlendMode.srcIn,
                        filterQuality: FilterQuality.low,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
                child,
              ],
            )
          : child,
    );
  }
}

/// 编辑式细分隔线。比 `Divider` 更克制:1px、mist 色、可带左右缩进。
///
/// 设计规范里「多用线条、分隔、边框,而不是炫技动效」——
/// 这条线是版式语言的一部分,所以做成组件而不是每处手写 Container。
class EditorialRule extends StatelessWidget {
  const EditorialRule({
    super.key,
    this.indent = 0,
    this.endIndent = 0,
    this.height = 1,
    this.color,
    this.opacity = 1,
  });

  final double indent;
  final double endIndent;
  final double height;
  final Color? color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final base = color ?? Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      padding: EdgeInsets.only(left: indent, right: endIndent),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: ColoredBox(
          color: opacity >= 1 ? base : base.withValues(alpha: opacity),
        ),
      ),
    );
  }
}

/// 杂志栏目名式小标签:`—— 标签` 或全大写宽字距。
///
/// 参考图里「今日会话」「设备」「工具」这类分区标题用的就是这个语言。
class Eyebrow extends StatelessWidget {
  const Eyebrow({
    super.key,
    required this.text,
    this.color,
    this.withRule = false,
  });

  final String text;
  final Color? color;

  /// 是否在文字后接一条延伸到行尾的细线(编辑式版头)。
  final bool withRule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurfaceVariant;
    final label = Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: fg,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w600,
      ),
    );
    if (!withRule) return label;
    return Row(
      children: [
        label,
        const SizedBox(width: 12),
        Expanded(child: EditorialRule(color: fg, opacity: 0.35)),
      ],
    );
  }
}

/// 页面身份标记(保留兼容,但浅/深都只用同一张图)。
///
/// 之前按页面分了三张浅色底图(chat/devices/settings 各一张),
/// 实测切换时仍有割裂感。现在**浅色统一一张、深色统一一张**,
/// 切 tab 时背景完全不变,只有内容在变,过渡自然平滑。
///
/// 这个枚举保留只是为了不破坏调用方签名,值不再影响选图。
enum PageBackdrop { chat, devices, settings }

/// 满幅背景图。
///
/// 浅色主题统一用 [PiAsset.bgCreamMain](用户指定的奶油纸张主背景),
/// 深色主题统一用 [PiAsset.bgCharcoal]。**同一主题内三页共用同一张图**,
/// 切 tab 时背景不动,只有前景内容在淡入淡出 —— 这是切换顺滑的关键。
///
/// 层次:底图 → 同色蒙版(压住纹理保正文可读) → 内容。
class BackdropPaper extends StatelessWidget {
  const BackdropPaper({
    super.key,
    required this.child,
    this.backdrop = PageBackdrop.chat,
    this.veil,
  });

  final Widget child;

  /// 保留兼容。浅/深都统一一张图,这个值不再影响选图。
  final PageBackdrop backdrop;

  /// 内容与背景之间的蒙版不透明度。
  final double? veil;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final image = isDark ? PiAsset.bgCharcoal : PiAsset.bgCreamMain;
    final veilAlpha = veil ?? (isDark ? 0.84 : 0.80);

    return Material(
      // Material 承载底色 + 提供 ink ripple 宿主(ListTile/InkWell 需要)。
      color: scheme.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Image.asset(
                image,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                excludeFromSemantics: true,
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: scheme.surface.withValues(alpha: veilAlpha),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// 矢量装饰:同心圆 + 星点 + 弧线,复古编辑感的几何语言。
///
/// 替代素材包里带白纸底的插画 PNG。纯 `CustomPaint` 画出来,
/// 天然透明、任何底色上都干净、还能跟着主题色走。
///
/// 加了一层极轻的「呼吸」:外圈同心圆缓慢收放,实心点缓慢明暗。
/// 节拍很慢(3.6s 一周期),只够让空状态「不死」,不会始鸡。
class EditorialOrnament extends StatefulWidget {
  const EditorialOrnament({
    super.key,
    this.size = 150,
    this.color,
    this.accent,
  });

  final double size;

  /// 线条色。默认 onSurfaceVariant。
  final Color? color;

  /// 点缀色(小圆点/星芒)。默认 primary。
  final Color? accent;

  @override
  State<EditorialOrnament> createState() => _EditorialOrnamentState();
}

class _EditorialOrnamentState extends State<EditorialOrnament>
    with SingleTickerProviderStateMixin {
  // 3.6s 一次呼吸:慢到不始鸡,但看一眼能看出「活的」。
  static const _period = Duration(milliseconds: 3600);

  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: _period,
  )..repeat();

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: widget.size,
      // AnimatedBuilder 重绘 CustomPaint,跟 _breath 同步。
      child: AnimatedBuilder(
        animation: _breath,
        builder: (context, _) {
          // 0→1→0 的钟形(sin(πt)):0/1 = 静止, 0.5 = 吸气峰。
          final t = _breath.value;
          final phase = (1 - math.cos(t * 2 * math.pi)) / 2;
          return CustomPaint(
            painter: _OrnamentPainter(
              line: widget.color ?? scheme.onSurfaceVariant,
              accent: widget.accent ?? scheme.primary,
              breath: phase,
            ),
          );
        },
      ),
    );
  }
}

class _OrnamentPainter extends CustomPainter {
  _OrnamentPainter({required this.line, required this.accent, this.breath = 0});

  final Color line;
  final Color accent;

  /// 呼吸相位 0~1(0/1 静止,0.5 吸气峰)。驱动外圈收放 + 点闪烁。
  final double breath;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w * 0.5, h * 0.52);

    // 呼吸:外圈随相位轻微放大、变淡;实心点随相位变亮。
    final expand = 1 + 0.06 * breath; // 外圈最多胀 6%
    final fade = 1 - 0.3 * breath; // 外圈透明度随呼吸降一点

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = line.withValues(alpha: 0.55);
    final strokeSoft = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = line.withValues(alpha: 0.3 * fade);
    final fillAccent = Paint()
      ..color = accent.withValues(alpha: 0.55 + 0.4 * breath);
    final fillSoft = Paint()..color = accent.withValues(alpha: 0.14);

    // 大色块:偏心的椭圆,像抽象色斑
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.62, h * 0.66),
        width: w * 0.5,
        height: h * 0.42,
      ),
      fillSoft,
    );

    // 三重同心圆(错位)。最外圈随呼吸胀缩,造「呼吸」主律动。
    canvas.drawCircle(center, w * 0.27 * expand, stroke);
    canvas.drawCircle(Offset(w * 0.42, h * 0.44), w * 0.19, strokeSoft);
    canvas.drawCircle(Offset(w * 0.6, h * 0.6), w * 0.23, strokeSoft);

    // 上方弧线
    final arc = Path()
      ..addArc(
        Rect.fromCircle(center: Offset(w * 0.5, h * 0.3), radius: w * 0.34),
        3.5,
        2.2,
      );
    canvas.drawPath(arc, stroke);

    // 实心小圆点(赤陶):随呼吸明暗闪烁
    canvas.drawCircle(Offset(w * 0.34, h * 0.3), 4.2, fillAccent);
    canvas.drawCircle(Offset(w * 0.72, h * 0.38), 2.6, fillAccent);

    // 四角星芒
    _star(canvas, Offset(w * 0.24, h * 0.68), 7, fillAccent);
    _star(canvas, Offset(w * 0.78, h * 0.24), 4.5, fillAccent);
  }

  /// 四角星:两条对角细长菱形。编辑式排版常用的点缀符号。
  void _star(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + r * 0.22, c.dy - r * 0.22, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + r * 0.22, c.dy + r * 0.22, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - r * 0.22, c.dy + r * 0.22, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - r * 0.22, c.dy - r * 0.22, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_OrnamentPainter old) =>
      old.line != line || old.accent != accent || old.breath != breath;
}
