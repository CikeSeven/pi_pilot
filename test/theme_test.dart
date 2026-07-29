import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/theme/accent.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:pi_pilot/ui/theme/highlight_theme.dart';
import 'package:pi_pilot/ui/theme/palette.dart';
import 'package:pi_pilot/ui/theme/semantic_colors.dart';
import 'package:pi_pilot/ui/theme/shapes.dart';
import 'package:pi_pilot/ui/theme/squircle.dart';
import 'package:pi_pilot/ui/theme/typography.dart';

/// WCAG 相对亮度对比度。
double _contrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);

  final la = luminance(a);
  final lb = luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('app theme', () {
    test('两套主题都暴露 PiColors 扩展', () {
      expect(buildDarkTheme().extension<PiColors>(), isNotNull);
      expect(buildLightTheme().extension<PiColors>(), isNotNull);
    });

    test('深浅主题 brightness 正确', () {
      expect(buildDarkTheme().brightness, Brightness.dark);
      expect(buildLightTheme().brightness, Brightness.light);
    });

    test('角标默认色不是错误红', () {
      // 角标最常见的用途是「标记此处」(抽屉里的「当前」会话),那不是错误。
      // 之前默认 scheme.error,结果「当前」两个字被涂成警告红,读起来像出了问题。
      // 真正表示错误的角标都在各自现场显式指定 error 色,所以默认必须中性。
      for (final accent in AppAccent.values) {
        for (final theme in [buildLightTheme(accent), buildDarkTheme(accent)]) {
          final scheme = theme.colorScheme;
          final badge = theme.badgeTheme;
          expect(badge.backgroundColor, isNot(scheme.error));
          expect(badge.backgroundColor, isNot(scheme.errorContainer));
          expect(badge.backgroundColor, scheme.primary);
          expect(badge.textColor, scheme.onPrimary);

          // 角标压在选中态的 secondaryContainer 上,分不开就等于没有角标
          expect(
            _contrast(badge.backgroundColor!, scheme.secondaryContainer),
            greaterThanOrEqualTo(3.0),
          );
          // 角标自己的字要能读。
          //
          // 门槛是 3.0 而不是 4.5:品牌色 #C85A3E 配奶油白的上限是 4.21,
          // 够不到 4.5。角标文字是 12sp 粗体等宽、按钮是 15sp 粗体,
          // 都属 WCAG large text(>=14pt bold),3:1 即达标。
          // 小字场景(正文/代码井/diff/工具卡)仍守 4.5,见下方「对比度守卫」。
          expect(
            _contrast(badge.textColor!, badge.backgroundColor!),
            greaterThanOrEqualTo(3.0),
          );
        }
      }
    });

    test('ansi 色板固定 16 色', () {
      expect(PiColors.dark.ansi, hasLength(16));
      expect(PiColors.light.ansi, hasLength(16));
    });

    test('PiColors.lerp 端点各归其主', () {
      final mid = PiColors.dark.lerp(PiColors.light, 0);
      expect(mid.success, PiColors.dark.success);
      final end = PiColors.dark.lerp(PiColors.light, 1);
      expect(end.success, PiColors.light.success);
      // 新增字段必须同步进 lerp,否则这里会抛
      expect(PiColors.light.lerp(PiColors.dark, 0.5), isA<PiColors>());
    });
  });

  group('accent', () {
    test('六个强调色产出互不相同的 primary', () {
      final primaries = {
        for (final accent in AppAccent.values)
          buildLightTheme(accent).colorScheme.primary,
      };
      expect(primaries, hasLength(AppAccent.values.length));
    });

    test('配色是手工构造的 Editorial Retro,不是种子直推', () {
      // 旧版断言「方案必须等于 ColorScheme.fromSeed 的结果」。
      // 新设计**刻意推翻**它:tonalSpot 会把任何种子推成现代冷灰中性面,
      // 而这套设计要求中性面是暖奶油纸。所以这里反向守卫。
      for (final accent in AppAccent.values) {
        final scheme = buildLightTheme(accent).colorScheme;
        expect(
          scheme,
          isNot(
            ColorScheme.fromSeed(
              seedColor: accent.seed,
              brightness: Brightness.light,
            ),
          ),
          reason: '${accent.name} 必须是手工配色,不能退回种子直推',
        );
      }
    });

    test('中性面是暖纸色,与强调色无关', () {
      // Editorial Retro 的核心:纸就是纸,不随强调色旋转色相。
      // 这与旧版「中性面板随强调色着色」的断言正好相反 —— 那是 tonalSpot 行为。
      final surfaces = {
        for (final accent in AppAccent.values)
          buildLightTheme(accent).colorScheme.surface,
      };
      expect(surfaces, hasLength(1), reason: '浅色纸底必须恒为 cream');
      expect(surfaces.single, PiPalette.cream);

      final darkSurfaces = {
        for (final accent in AppAccent.values)
          buildDarkTheme(accent).colorScheme.surface,
      };
      expect(darkSurfaces, hasLength(1), reason: '深色纸底必须恒为 nightPaper');
      expect(darkSurfaces.single, PiPalette.nightPaper);
    });

    test('色板里没有科技蓝', () {
      // 设计规范硬要求:不走科技蓝。唯一的冷色 slate 也必须是做旧灰蓝,
      // 蓝色通道不能显著压过红色通道。
      for (final accent in AppAccent.values) {
        final c = accent.seed;
        expect(c.b - c.r, lessThan(0.25), reason: '${accent.name} 偏科技蓝了');
      }
    });

    test('默认强调色是赤陶', () {
      expect(
        buildLightTheme().colorScheme,
        buildLightTheme(AppAccent.terracotta).colorScheme,
      );
    });

    test('fromName 回退赤陶(含旧色名)', () {
      expect(AppAccent.fromName('olive'), AppAccent.olive);
      expect(AppAccent.fromName('nonsense'), AppAccent.terracotta);
      expect(AppAccent.fromName(null), AppAccent.terracotta);
      // 旧版持久化过的色名必须安全回退,不能崩
      for (final legacy in [
        'blue',
        'purple',
        'pink',
        'orange',
        'green',
        'teal',
      ]) {
        expect(AppAccent.fromName(legacy), AppAccent.terracotta);
      }
    });
  });

  group('Editorial Retro 版式守卫', () {
    test('非 Cupertino 转场 / 水波纹保留但含蓄', () {
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        expect(theme.splashFactory, isNot(NoSplash.splashFactory));
        expect(
          theme.pageTransitionsTheme.builders[TargetPlatform.android],
          isA<FadeForwardsPageTransitionsBuilder>(),
        );
      }
    });

    test('阴影收敛:卡片/对话框允许 ≤1 微阴影,其余零阴影', () {
      // 初版守卫是「连浮层也零阴影」;后续设计细化为:
      // 卡片/对话框/弹层允许 ≤1 的微阴影与底纸分离(app_theme.dart
      // 里标注「微浮起:替代纯零阴影」),其余一律零阴影。
      // 这里按分支最终代码状态收录这个演变。
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        expect(
          theme.cardTheme.elevation,
          lessThanOrEqualTo(1),
          reason: '卡片最多微阴影',
        );
        expect(
          theme.dialogTheme.elevation,
          lessThanOrEqualTo(1),
          reason: '对话框最多微阴影',
        );
        expect(theme.bottomSheetTheme.modalElevation, lessThanOrEqualTo(1));
        expect(theme.drawerTheme.elevation, 0, reason: '抽屉不投影');
        expect(theme.appBarTheme.elevation, 0, reason: '顶栏不投影');
        expect(theme.appBarTheme.scrolledUnderElevation, 0);
        expect(theme.snackBarTheme.elevation, 0);
        expect(theme.floatingActionButtonTheme.elevation, 0);
        expect(theme.popupMenuTheme.elevation, 0);
        expect(theme.navigationBarTheme.elevation, 0);
      }
    });

    test('卡片带 1px 描边', () {
      // 描边是编辑式版式的骨架线,去掉阴影之后它承担全部分界职责。
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        final shape = theme.cardTheme.shape! as SquircleBorder;
        expect(shape.side.color, theme.colorScheme.outlineVariant);
        expect(shape.side.width, greaterThan(0));
      }
    });

    test('内容区靠纸色分层', () {
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        expect(theme.cardTheme.color, isNot(theme.colorScheme.surface));
        expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      }
    });

    test('输入框只有一套形状', () {
      final theme = buildLightTheme();
      double radiusOf(InputBorder? border) =>
          ((border! as OutlineInputBorder).borderRadius)
              .resolve(TextDirection.ltr)
              .topLeft
              .x;
      final input = theme.inputDecorationTheme;
      for (final border in [
        input.border,
        input.enabledBorder,
        input.focusedBorder,
        input.errorBorder,
        input.focusedErrorBorder,
      ]) {
        expect(radiusOf(border), PiShape.md);
      }
    });

    test('圆角收敛到编辑式区间', () {
      // 三档收敛:sm 8 / md 14 / lg 22,差值明显、用途固定。
      // 纸卡用中档(裁切感),对话框/弹层用高档,且全部走 squircle。
      final theme = buildLightTheme();
      double radiusOf(ShapeBorder? shape) => (shape as SquircleBorder)
          .borderRadius
          .resolve(TextDirection.ltr)
          .topLeft
          .x;
      expect(radiusOf(theme.cardTheme.shape), PiShape.md);
      expect(radiusOf(theme.dialogTheme.shape), PiShape.lg);
      // 单调递增且收敛:最大档 22,不再像旧版 xxl 那样到 28。
      expect(PiShape.sm, lessThan(PiShape.md));
      expect(PiShape.md, lessThan(PiShape.lg));
      expect(PiShape.lg, lessThanOrEqualTo(22));
    });

    test('底部导航是同色通栏,浅色不用黑、深色抬升一档', () {
      // 浅色模式:底栏用一级卡片面(surfaceContainerLow,象牙白),
      // **不是黑色** —— 奶油纸上贴黑胶带会割裂突兀。
      // 深色模式:页面是暖炭黑,底栏用 surfaceContainerHigh(暖石墨灰)才分得开。
      final light = buildLightTheme();
      expect(
        light.navigationBarTheme.backgroundColor,
        light.colorScheme.surfaceContainerLow,
      );
      // 浅色底栏绝不能是 inverseSurface(那是暖炭黑,会被吐槽为黑底栏)
      expect(
        light.navigationBarTheme.backgroundColor,
        isNot(light.colorScheme.inverseSurface),
      );
      final dark = buildDarkTheme();
      expect(
        dark.navigationBarTheme.backgroundColor,
        dark.colorScheme.surfaceContainerHigh,
      );
      // 深色底栏必须和页面底分得开,否则底栏消失
      expect(
        _contrast(
          dark.navigationBarTheme.backgroundColor!,
          dark.colorScheme.surface,
        ),
        greaterThanOrEqualTo(1.2),
      );
    });
  });

  group('对比度守卫', () {
    test('on-色对容器 ≥ 4.5:1', () {
      for (final piColors in [PiColors.light, PiColors.dark]) {
        final pairs = <String, (Color, Color)>{
          'success': (piColors.onSuccessContainer, piColors.successContainer),
          'warning': (piColors.onWarningContainer, piColors.warningContainer),
          'terminal': (
            piColors.onToolTerminalContainer,
            piColors.toolTerminalContainer,
          ),
          'read': (piColors.onToolReadContainer, piColors.toolReadContainer),
          'edit': (piColors.onToolEditContainer, piColors.toolEditContainer),
          'search': (
            piColors.onToolSearchContainer,
            piColors.toolSearchContainer,
          ),
          'files': (piColors.onToolFilesContainer, piColors.toolFilesContainer),
          'extension': (
            piColors.onToolExtensionContainer,
            piColors.toolExtensionContainer,
          ),
          'generic': (
            piColors.onToolGenericContainer,
            piColors.toolGenericContainer,
          ),
          // 8 组身份色(会话头像、设置分组图标)必须和工具色守一样的线
          for (var i = 0; i < piColors.identity.length; i++)
            'identity$i': (piColors.onIdentity[i], piColors.identity[i]),
          'diffAdd': (piColors.diffAddFg, piColors.diffAddBg),
          'diffDel': (piColors.diffDelFg, piColors.diffDelBg),
          'codeWell': (piColors.codeWellFg, piColors.codeWellBg),
        };
        pairs.forEach((name, pair) {
          final (fg, bg) = pair;
          expect(
            _contrast(fg, bg),
            greaterThanOrEqualTo(4.5),
            reason: '$name 对比度不足',
          );
        });
      }
    });

    test('ANSI 16 色对代码井底 ≥ 4.5:1', () {
      for (final piColors in [PiColors.light, PiColors.dark]) {
        for (final (index, color) in piColors.ansi.indexed) {
          expect(
            _contrast(color, piColors.codeWellBg),
            greaterThanOrEqualTo(4.5),
            reason: 'ansi[$index] 在代码井上不可读',
          );
        }
      }
    });
  });

  group('身份色', () {
    test('8 组配对齐全', () {
      for (final piColors in [PiColors.light, PiColors.dark]) {
        expect(piColors.identity.length, 8);
        expect(piColors.onIdentity.length, 8);
        // 互不相同,否则「一眼分辨」就失效了
        expect(piColors.identity.toSet().length, 8);
      }
    });

    test('identityIndex 稳定且落在范围内', () {
      // 不能用 String.hashCode —— Dart 不保证它跨进程稳定,
      // 那样重启 app 之后所有会话的颜色会整体重排。
      const key = '/home/user/projects/pipilot';
      final first = PiColors.identityIndex(key);
      expect(first, PiColors.identityIndex(key));
      expect(first, inInclusiveRange(0, 7));
      for (final other in ['/a', '/b', '', 'x' * 200]) {
        expect(PiColors.identityIndex(other), inInclusiveRange(0, 7));
      }
    });
  });

  group('typography', () {
    test('衬线负责气质:headline/display 走 serif 族', () {
      // 「衬线体只负责气质,不负责大段信息」——
      // display/headline 必须是衬线,title/body/label 必须不是。
      final t = AppType.textTheme;
      for (final style in [
        t.displayLarge,
        t.displayMedium,
        t.displaySmall,
        t.headlineLarge,
        t.headlineMedium,
        t.headlineSmall,
      ]) {
        expect(style!.fontFamily, AppType.serifFamily);
      }
      for (final style in [
        t.titleLarge,
        t.titleMedium,
        t.bodyLarge,
        t.bodyMedium,
        t.labelLarge,
      ]) {
        expect(style!.fontFamily, isNot(AppType.serifFamily));
      }
    });

    test('衬线出口都带 serif family 与 fallback', () {
      for (final style in [
        AppType.serif(),
        AppType.wordmark(),
        AppType.answerHeadline(),
        AppType.displayTitle(),
        AppType.serifItalic(),
      ]) {
        expect(style.fontFamily, AppType.serifFamily);
        expect(style.fontFamilyFallback, isNotEmpty);
      }
      expect(AppType.serifItalic().fontStyle, FontStyle.italic);
      // eyebrow 是功能标签,不能用衬线
      expect(AppType.eyebrow().fontFamily, isNot(AppType.serifFamily));
      expect(AppType.eyebrow().letterSpacing, greaterThan(1));
    });

    test('mono 样式带 JetBrainsMono 与 fallback', () {
      final style = AppType.mono();
      expect(style.fontFamily, 'JetBrainsMono');
      expect(style.fontFamilyFallback, contains('monospace'));
      // 11.5 低于 11sp 可访问性下限的邻域,且不在任何字阶步进上 → 提到 12
      expect(AppType.monoSmall().fontSize, 12);
      expect(AppType.monoLabel().fontSize, 12);
      // mono 三档必须单调不降,否则「小号」比「标签」还大
      expect(
        AppType.monoSmall().fontSize!,
        lessThanOrEqualTo(AppType.mono().fontSize!),
      );
    });
  });

  group('highlight theme', () {
    test('两套亮度都有 root/keyword/string/comment 键', () {
      for (final brightness in [Brightness.dark, Brightness.light]) {
        final map = piHighlightTheme(brightness);
        expect(map['root'], isNotNull);
        expect(map['keyword'], isNotNull);
        expect(map['string'], isNotNull);
        expect(map['comment'], isNotNull);
      }
    });
  });
}
