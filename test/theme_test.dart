import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/theme/accent.dart';
import 'package:pi_pilot/ui/theme/app_theme.dart';
import 'package:pi_pilot/ui/theme/highlight_theme.dart';
import 'package:pi_pilot/ui/theme/palette.dart';
import 'package:pi_pilot/ui/theme/semantic_colors.dart';
import 'package:pi_pilot/ui/theme/shapes.dart';
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
    test('方案完全由种子推导(挡住任何偷偷的 copyWith)', () {
      for (final accent in AppAccent.values) {
        expect(
          buildLightTheme(accent).colorScheme,
          ColorScheme.fromSeed(
            seedColor: accent.seed,
            brightness: Brightness.light,
            dynamicSchemeVariant: PiPalette.variant,
          ),
          reason: '${accent.name} 浅色方案必须等于种子直推的结果',
        );
        expect(
          buildDarkTheme(accent).colorScheme,
          ColorScheme.fromSeed(
            seedColor: accent.seed,
            brightness: Brightness.dark,
            dynamicSchemeVariant: PiPalette.variant,
          ),
        );
      }
    });

    test('六个强调色产出互不相同的 primary', () {
      final primaries = {
        for (final accent in AppAccent.values)
          buildLightTheme(accent).colorScheme.primary,
      };
      expect(primaries, hasLength(AppAccent.values.length));
    });

    test('中性面板随强调色着色(tonalSpot 的刻意设计)', () {
      expect(
        buildLightTheme(AppAccent.pink).colorScheme.surface,
        isNot(buildLightTheme(AppAccent.blue).colorScheme.surface),
      );
      expect(
        buildDarkTheme(AppAccent.green).colorScheme.surfaceContainerLow,
        isNot(buildDarkTheme(AppAccent.teal).colorScheme.surfaceContainerLow),
      );
    });

    test('默认强调色是蓝色', () {
      expect(
        buildLightTheme().colorScheme,
        buildLightTheme(AppAccent.blue).colorScheme,
      );
    });

    test('fromName 回退蓝色', () {
      expect(AppAccent.fromName('teal'), AppAccent.teal);
      expect(AppAccent.fromName('nonsense'), AppAccent.blue);
      expect(AppAccent.fromName(null), AppAccent.blue);
    });
  });

  group('Material 3 健全性', () {
    test('未禁用 surfaceTint / 未禁用水波纹 / 非 Cupertino 转场', () {
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        expect(theme.colorScheme.surfaceTint, isNot(Colors.transparent));
        expect(theme.splashFactory, isNot(NoSplash.splashFactory));
        expect(
          theme.pageTransitionsTheme.builders[TargetPlatform.android],
          isA<FadeForwardsPageTransitionsBuilder>(),
        );
      }
    });

    test('内容区是平的,浮层不是', () {
      // 上一版把 elevation 全打开,一屏几十张卡片各带一层投影,观感是上个
      // 年代的 UI。内容区改为**零投影**,层次由 surfaceContainer* 色阶承担;
      // 只有真正浮在遮罩之上的东西才留阴影。
      //
      // 别把这些改回非零 —— 那正是被否掉的那一版。
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        expect(theme.cardTheme.elevation, 0, reason: '卡片不投影');
        expect(theme.drawerTheme.elevation, 0, reason: '抽屉不投影');
        expect(theme.appBarTheme.scrolledUnderElevation, 0, reason: '顶栏滚动时不投影');

        // 浮层保留,但要比 M3 默认的 6 轻
        expect(theme.dialogTheme.elevation, greaterThan(0));
        expect(theme.dialogTheme.elevation, lessThan(6));
        expect(theme.bottomSheetTheme.modalElevation, greaterThan(0));
        expect(theme.snackBarTheme.elevation, lessThan(6));
        // FAB 浮在消息流上,不能吃 M3 默认的 6
        expect(theme.floatingActionButtonTheme.elevation, lessThan(3));
      }
    });

    test('内容区靠色阶而不是阴影分层', () {
      // 去掉投影之后,卡片与背景必须仍然分得开 —— 这是扁平化能成立的前提
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        expect(theme.cardTheme.color, isNot(theme.colorScheme.surface));
        expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      }
    });

    test('输入框只有一套形状', () {
      // 曾经 composer 本地重声明 border(28)与主题(20)并存,
      // 同一个 app 里出现两种输入框形状。
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
        expect(radiusOf(border), PiShape.xxl);
      }
    });

    test('卡片/对话框圆角不小于设计下限', () {
      final theme = buildLightTheme();
      double radiusOf(ShapeBorder? shape) => (shape as RoundedRectangleBorder)
          .borderRadius
          .resolve(TextDirection.ltr)
          .topLeft
          .x;
      expect(radiusOf(theme.cardTheme.shape), greaterThanOrEqualTo(28));
      expect(radiusOf(theme.dialogTheme.shape), greaterThanOrEqualTo(28));
      expect(PiShape.xl, greaterThanOrEqualTo(20));
      expect(PiShape.xxl, greaterThanOrEqualTo(28));
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
