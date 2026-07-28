import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accent.dart';
import 'palette.dart';
import 'semantic_colors.dart';
import 'shapes.dart';
import 'typography.dart';

ThemeData buildLightTheme([AppAccent accent = AppAccent.blue]) => _build(
  PiPalette.lightScheme(accent),
  PiColors.light,
  SystemUiOverlayStyle.dark,
);

ThemeData buildDarkTheme([AppAccent accent = AppAccent.blue]) => _build(
  PiPalette.darkScheme(accent),
  PiColors.dark,
  SystemUiOverlayStyle.light,
);

/// Material 3:大圆角、色调表面、真实 elevation + surfaceTint、水波纹回归。
/// 深浅两套走**同一份**规格——不再有 `isDark ? … : …` 的阴影/描边分支。
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

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: AppType.textTheme,
    extensions: [piColors],
    pageTransitionsTheme: transitions,
    // splashFactory 不设置 → M3 默认水波纹回归
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      // 顶栏是 primaryContainer 实色块,滚动阴影既看不出层次又显旧
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppType.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
      ),
      systemOverlayStyle: overlayStyle.copyWith(
        statusBarColor: Colors.transparent,
      ),
    ),
    // **内容区一律不投影**。上一版把 elevation 打开,结果一屏几十张卡片各带
    // 一层阴影,观感是上个年代的 UI。层次改由 surfaceContainer* 色阶承担:
    // scaffold 是 surface,卡片是 surfaceContainerLow,天然差一档。
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: PiShape.messageCard,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.xxl),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.xxl),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.xxl),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.xxl),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiShape.xxl),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 40)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiShape.sm),
      ),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.secondaryContainer,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSecondaryContainer,
        side: BorderSide(color: scheme.outline),
        minimumSize: const Size(0, 44),
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiShape.xxl),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      constraints: const BoxConstraints(minHeight: 48),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.error,
      textColor: scheme.onError,
      // M3 默认 16dp 会纵向裁切 12sp 等宽字——这是必需项不是装饰
      largeSize: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: AppType.monoLabel(),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: PiShape.card,
      collapsedShape: PiShape.card,
      backgroundColor: scheme.surfaceContainerLow,
      collapsedBackgroundColor: scheme.surfaceContainerLow,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      iconColor: scheme.primary,
      collapsedIconColor: scheme.onSurfaceVariant,
    ),
    dialogTheme: DialogThemeData(
      // 浮层只留一丝阴影帮助分离,重影会破坏扁平的高级感
      elevation: 1,
      backgroundColor: scheme.surfaceContainerHigh,
      shape: PiShape.dialog,
      titleTextStyle: AppType.textTheme.headlineSmall?.copyWith(
        color: scheme.onSurface,
      ),
      contentTextStyle: AppType.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      elevation: 1,
      modalElevation: 1,
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
      dragHandleSize: const Size(32, 4),
      clipBehavior: Clip.antiAlias,
      shape: PiShape.sheet,
      showDragHandle: true,
    ),
    snackBarTheme: SnackBarThemeData(
      elevation: 1,
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      actionTextColor: scheme.inversePrimary,
      insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        elevation: const WidgetStatePropertyAll(1),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiShape.md),
          ),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: AppType.textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
      ),
      subtitleTextStyle: AppType.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      selectedColor: scheme.onSecondaryContainer,
      selectedTileColor: scheme.secondaryContainer,
      minVerticalPadding: 12,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      // 回到底部按钮浮在消息流上,1 就够;默认的 6 会在内容区留一坨影子
      elevation: 1,
      focusElevation: 1,
      hoverElevation: 1,
      highlightElevation: 1,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiShape.md),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: scheme.surfaceTint,
      // 抽屉靠色阶 + 遮罩已经足够分离
      elevation: 0,
      width: 320,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(PiShape.xxl),
        ),
      ),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: const StadiumBorder(),
      tileHeight: 56,
    ),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Icon(Icons.check, size: 16)
            : null,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(PiShape.xs),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
}
