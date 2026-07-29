import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accent.dart';
import 'palette.dart';
import 'semantic_colors.dart';
import 'shapes.dart';
import 'typography.dart';
import 'squircle.dart';

ThemeData buildLightTheme([AppAccent accent = AppAccent.terracotta]) => _build(
  PiPalette.lightScheme(accent),
  PiColors.light,
  SystemUiOverlayStyle.dark,
);

ThemeData buildDarkTheme([AppAccent accent = AppAccent.terracotta]) => _build(
  PiPalette.darkScheme(accent),
  PiColors.dark,
  SystemUiOverlayStyle.light,
);

/// Editorial Retro 主题。
///
/// 三条铁律,贯穿所有组件默认样式:
/// 1. **微阴影**。卡片/对话框/弹层/输入条 elevation = 1(极淡浮起感),
///    不是 M3 默认的 6(太重),也不是零(卡片会融进背景)。浮层和内容区用
///    同一套描边语言,阴影只是辅助层次。
///    层次由「纸的深浅 + 1px 描边」承担。设计规范原话:
///    「卡片不需要太多阴影」「更像印刷排版」。
/// 2. **细描边**。卡片、井、chip、按钮一律 1px outlineVariant 描边。
///    这是编辑式版式的骨架线。
/// 3. **方正圆角**。见 [PiShape]——卡片 14,只有胶囊类走 stadium。
///
/// 与旧版(M3 fromSeed + 大圆角 + surfaceTint)的关系:整套推翻。
ThemeData _build(
  ColorScheme scheme,
  PiColors piColors,
  SystemUiOverlayStyle overlayStyle,
) {
  const transitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
    },
  );

  final border = scheme.outlineVariant;
  final isDark = scheme.brightness == Brightness.dark;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: AppType.textTheme,
    extensions: [piColors],
    pageTransitionsTheme: transitions,
    // 水波纹保留,但复古纸面上要更含蓄:用 splashColor 压低。
    splashColor: scheme.primary.withValues(alpha: 0.07),
    highlightColor: scheme.primary.withValues(alpha: 0.04),

    appBarTheme: AppBarTheme(
      // 顶栏就是纸本身,不再是 primaryContainer 实色块——
      // 参考图里顶栏与内容同底,靠字标和一条细线分隔。
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.wordmark(color: scheme.onSurface),
      systemOverlayStyle: overlayStyle.copyWith(
        statusBarColor: Colors.transparent,
      ),
    ),

    // 纸卡:ivory 面 + 1px 描边 + 零阴影。
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      // 微浮起:替代纯零阴影,让卡片与背景有层次区分。
      elevation: 1,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: PiShape.outlinedCard(border),
    ),

    // 输入框:纸上的书写区。深一档纸底 + 描边,聚焦时描边转主色。
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),

    // 主按钮:陶土橙实心,方正圆角(不是胶囊)——编辑式按钮更像印章。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 50),
        padding: const EdgeInsets.symmetric(horizontal: 26),
        elevation: 0,
        shape: SquircleBorder(
          borderRadius: BorderRadius.circular(PiShape.md),
        ),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 50),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        side: BorderSide(color: scheme.outline),
        shape: SquircleBorder(
          borderRadius: BorderRadius.circular(PiShape.md),
        ),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 42),
        shape: SquircleBorder(
          borderRadius: BorderRadius.circular(PiShape.sm),
        ),
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),

    // chip:编辑式标签,方正 + 描边。
    chipTheme: ChipThemeData(
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
      side: BorderSide(color: border),
      backgroundColor: scheme.surfaceContainerLow,
      selectedColor: scheme.primaryContainer,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        side: BorderSide(color: scheme.outline),
        minimumSize: const Size(0, 46),
        shape: SquircleBorder(
          borderRadius: BorderRadius.circular(PiShape.sm),
        ),
      ),
    ),

    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      shape: WidgetStatePropertyAll(
        SquircleBorder(
          borderRadius: BorderRadius.circular(PiShape.md),
          side: BorderSide(color: border),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      constraints: const BoxConstraints(minHeight: 50),
    ),

    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
      largeSize: 21,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: AppType.monoLabel(),
    ),

    expansionTileTheme: ExpansionTileThemeData(
      shape: PiShape.outlinedCard(border),
      collapsedShape: PiShape.outlinedCard(border),
      backgroundColor: scheme.surfaceContainerLow,
      collapsedBackgroundColor: scheme.surfaceContainerLow,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      iconColor: scheme.primary,
      collapsedIconColor: scheme.onSurfaceVariant,
    ),

    // 浮层:允许极轻阴影(需要和底纸分离),但形状和描边保持一致。
    // 对话框:微阴影,从纸面浮起(替代纯零阴影)。
    dialogTheme: DialogThemeData(
      elevation: 1,
      backgroundColor: scheme.surfaceContainerLow,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(color: border),
      ),
      titleTextStyle: AppType.serif(
        size: 22,
        weight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      contentTextStyle: AppType.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),

    // 底部弹层:微阴影,浮在 scrim 之上。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      elevation: 1,
      modalElevation: 0,
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.35),
      dragHandleSize: const Size(36, 4),
      clipBehavior: Clip.antiAlias,
      shape: PiShape.sheet,
      showDragHandle: true,
    ),

    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 14),
      actionTextColor: scheme.inversePrimary,
      insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
    ),

    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
      linearMinHeight: 2,
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
        side: BorderSide(color: border),
      ),
    ),

    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(
          SquircleBorder(
            borderRadius: BorderRadius.circular(PiShape.md),
            side: BorderSide(color: border),
          ),
        ),
      ),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: AppType.textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: AppType.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      selectedColor: scheme.onPrimaryContainer,
      selectedTileColor: scheme.primaryContainer,
      minVerticalPadding: 13,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
      ),
    ),

    // 抽屉与页面同一套纸色。旧版这里浅色模式也强制 charcoal,
    // 结果抽屉是黑的、页面是奶油的,拉开就撕裂。
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      width: 330,
      shape: const SquircleBorder(
        // 抽屉从左侧滑出:右侧上方圆角(开口的纸角),右下方直角(贴屏底不悬空)。
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(PiShape.lg),
        ),
      ),
    ),

    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
      tileHeight: 54,
    ),

    // 底部导航:**同色通栏,不用黑色**。
    //
    // 浅色模式:用一级卡片面(象牙白)+ 顶部一条细描边。和页面是同一张纸的
    // 不同折页,而不是「奶油纸上贴一条黑胶带」——后者割裂又突兀。
    // 深色模式:用抬升一档的暖石墨灰(页面是暖炭黑,底栏要高一档才分得开)。
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isDark
          ? scheme.surfaceContainerHigh
          : scheme.surfaceContainerLow,
      // 顶部细描边:代替悬浮圆角条的「边界」,通栏不漏底。
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant.withValues(alpha: 0.72),
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant.withValues(alpha: 0.72),
        ),
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Icon(Icons.check, size: 15)
            : null,
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
}
