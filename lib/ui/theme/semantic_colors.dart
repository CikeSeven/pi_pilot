import 'package:flutter/material.dart';

/// 语义色扩展:与强调色**无关**的固定色。
///
/// 为什么固定而不从 scheme 派生:一张 `bash` 卡在蓝色主题和粉色主题下必须长得一样,
/// 色相本身就是语义。若派生自 `tertiary/secondary`,7 个工具类别会塌缩成 2 个角色,
/// 恰好在同屏颜色最多的地方杀死「色彩丰富」,还会让 diff 的红绿随主题旋转。
///
/// 可读性铁律:所有 mono / 代码 / diff / ANSI 面必须铺 [codeWellBg],
/// **绝不能**用 `colorScheme.surface*`(那是随强调色着色的),
/// 只有固定的井底才能保证这些固定前景色在任何主题下的对比度成立。
/// 下方所有 on-色对容器、以及 ANSI 16 色对井底,均 ≥ 4.5:1(见 theme_test)。
class PiColors extends ThemeExtension<PiColors> {
  const PiColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.diffAddBg,
    required this.diffAddFg,
    required this.diffDelBg,
    required this.diffDelFg,
    required this.diffHunkFg,
    required this.codeWellBg,
    required this.codeWellFg,
    required this.codeWellBorder,
    required this.lineNumberFg,
    required this.ansi,
    required this.identity,
    required this.onIdentity,
    required this.toolTerminalContainer,
    required this.onToolTerminalContainer,
    required this.toolReadContainer,
    required this.onToolReadContainer,
    required this.toolEditContainer,
    required this.onToolEditContainer,
    required this.toolSearchContainer,
    required this.onToolSearchContainer,
    required this.toolFilesContainer,
    required this.onToolFilesContainer,
    required this.toolExtensionContainer,
    required this.onToolExtensionContainer,
    required this.toolGenericContainer,
    required this.onToolGenericContainer,
  });

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  final Color diffAddBg;
  final Color diffAddFg;
  final Color diffDelBg;
  final Color diffDelFg;
  final Color diffHunkFg;

  final Color codeWellBg;
  final Color codeWellFg;
  final Color codeWellBorder;
  final Color lineNumberFg;

  /// SGR 30-37 + 90-97(标准 8 色 + 亮色 8 色)。
  final List<Color> ansi;

  /// 身份标识色(会话头像、设置分组图标)。8 组容器 / on-容器配对。
  ///
  /// 与工具色同理:**必须固定,不能随 accent 旋转**。否则同一个会话昨天是蓝的、
  /// 换个主题就变成橙的,标识色就失去了"一眼认出"的全部意义。
  /// 用 `identityIndex()` 从稳定的字符串键取下标。
  final List<Color> identity;
  final List<Color> onIdentity;

  /// 由稳定字符串(如 cwd)映射到 identity 下标。
  ///
  /// 不用 `String.hashCode` —— Dart 不保证它跨进程稳定,那样重启 app
  /// 会话颜色就会整体重排。这里用固定的 FNV-1a。
  static int identityIndex(String key, [int slots = 8]) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash % slots;
  }

  // 工具分类色:M3 tonal 容器 + on-容器配对。
  final Color toolTerminalContainer;
  final Color onToolTerminalContainer;
  final Color toolReadContainer;
  final Color onToolReadContainer;
  final Color toolEditContainer;
  final Color onToolEditContainer;
  final Color toolSearchContainer;
  final Color onToolSearchContainer;
  final Color toolFilesContainer;
  final Color onToolFilesContainer;
  final Color toolExtensionContainer;
  final Color onToolExtensionContainer;
  final Color toolGenericContainer;
  final Color onToolGenericContainer;

  static PiColors of(BuildContext context) =>
      Theme.of(context).extension<PiColors>()!;

  static const light = PiColors(
    // 状态色一律降饱和 —— 鲜绿 #00C853 / 鲜红 #FF0000 会瞬间变互联网工具化。
    success: Color(0xFF738261),
    onSuccess: Color(0xFFFFF8EE),
    successContainer: Color(0xFFDFE3D2),
    onSuccessContainer: Color(0xFF2C3124),
    warning: Color(0xFFB7743F),
    onWarning: Color(0xFFFFF8EE),
    warningContainer: Color(0xFFF3E3CC),
    onWarningContainer: Color(0xFF33230C),
    diffAddBg: Color(0xFFE0E7D4),
    diffAddFg: Color(0xFF4A5A38),
    diffDelBg: Color(0xFFF4DDD6),
    diffDelFg: Color(0xFF8F3A2C),
    diffHunkFg: Color(0xFF716860),
    // 代码井底:比页面纸深一档的暖米色,不是冷灰白。
    codeWellBg: Color(0xFFF1E6D6),
    codeWellFg: Color(0xFF2B2825),
    codeWellBorder: Color(0xFFD8C9B8),
    lineNumberFg: Color(0xFF9B9187),
    // ANSI 16 色:全部做旧到印刷墨色系,在暖米井底上保持 >= 4.5:1。
    ansi: [
      Color(0xFF2B2825),
      Color(0xFF9E3A2B),
      Color(0xFF4A5A38),
      Color(0xFF7A5A1E),
      Color(0xFF41566A),
      Color(0xFF6B4666),
      Color(0xFF2F5F68),
      Color(0xFF5C5548),
      Color(0xFF6B6459),
      Color(0xFFA8432E),
      Color(0xFF4E6B36),
      Color(0xFF7F6021),
      Color(0xFF4A6076),
      Color(0xFF7C5175),
      Color(0xFF376C75),
      Color(0xFF3A342B),
    ],
    // 身份色:复古色卡的八个淡调容器。
    identity: [
      Color(0xFFF4DED6), // 赤陶
      Color(0xFFF0D8D0), // 砖红
      Color(0xFFDFE3D2), // 橄榄
      Color(0xFFDEE5D8), // 鼠尾草
      Color(0xFFF3DFDA), // 灰粉
      Color(0xFFDAE1E6), // 灰蓝
      Color(0xFFF3E3CC), // 麦黄
      Color(0xFFE4DDE9), // 灰紫
    ],
    onIdentity: [
      Color(0xFF4A1F14),
      Color(0xFF3D160C),
      Color(0xFF2C3124),
      Color(0xFF2A3227),
      Color(0xFF44201A),
      Color(0xFF232D34),
      Color(0xFF33230C),
      Color(0xFF2E2637),
    ],
    toolTerminalContainer: Color(0xFFE2DCC9),
    onToolTerminalContainer: Color(0xFF33301F),
    toolReadContainer: Color(0xFFDAE1E6),
    onToolReadContainer: Color(0xFF232D34),
    toolEditContainer: Color(0xFFF3E3CC),
    onToolEditContainer: Color(0xFF33230C),
    toolSearchContainer: Color(0xFFE4DDE9),
    onToolSearchContainer: Color(0xFF2E2637),
    toolFilesContainer: Color(0xFFDEE5D8),
    onToolFilesContainer: Color(0xFF2A3227),
    toolExtensionContainer: Color(0xFFDFE3D2),
    onToolExtensionContainer: Color(0xFF2C3124),
    toolGenericContainer: Color(0xFFE7DACA),
    onToolGenericContainer: Color(0xFF3A342B),
  );

  static const dark = PiColors(
    success: Color(0xFF99AA80),
    onSuccess: Color(0xFF222A18),
    successContainer: Color(0xFF3C4630),
    onSuccessContainer: Color(0xFFDCE2CC),
    warning: Color(0xFFD78D55),
    onWarning: Color(0xFF33210B),
    warningContainer: Color(0xFF52381A),
    onWarningContainer: Color(0xFFF3E3CC),
    diffAddBg: Color(0xFF2C3524),
    diffAddFg: Color(0xFF99AA80),
    diffDelBg: Color(0xFF3A1E18),
    diffDelFg: Color(0xFFE08A78),
    diffHunkFg: Color(0xFFBBB0A4),
    // 夜里的牛皮纸井底 —— 不是纯黑。
    codeWellBg: Color(0xFF1E1D1B),
    codeWellFg: Color(0xFFF3EBDD),
    codeWellBorder: Color(0xFF575149),
    lineNumberFg: Color(0xFF8D857C),
    ansi: [
      Color(0xFF9A9080),
      Color(0xFFD0695A),
      Color(0xFF99AA80),
      Color(0xFFD9A45F),
      Color(0xFF9BAEB9),
      Color(0xFFC49CBE),
      Color(0xFF8FBCC2),
      Color(0xFFCFC5B4),
      Color(0xFFBBB0A4),
      Color(0xFFE08A78),
      Color(0xFFAEBF93),
      Color(0xFFE6C182),
      Color(0xFFB2C3CE),
      Color(0xFFD6B2CE),
      Color(0xFFA6CDD3),
      Color(0xFFF3EBDD),
    ],
    identity: [
      Color(0xFF6B3423), // 赤陶
      Color(0xFF5E2718), // 砖红
      Color(0xFF404733), // 橄榄
      Color(0xFF3C4739), // 鼠尾草
      Color(0xFF64362E), // 灰粉
      Color(0xFF3A464F), // 灰蓝
      Color(0xFF52381A), // 麦黄
      Color(0xFF463C51), // 灰紫
    ],
    onIdentity: [
      Color(0xFFF6E1D8),
      Color(0xFFF2DBD3),
      Color(0xFFDCE2CC),
      Color(0xFFDBE3D5),
      Color(0xFFF4E2DD),
      Color(0xFFD9E2E7),
      Color(0xFFF3E3CC),
      Color(0xFFE4DDE9),
    ],
    toolTerminalContainer: Color(0xFF3D392C),
    onToolTerminalContainer: Color(0xFFE2DCC9),
    toolReadContainer: Color(0xFF3A464F),
    onToolReadContainer: Color(0xFFD9E2E7),
    toolEditContainer: Color(0xFF52381A),
    onToolEditContainer: Color(0xFFF3E3CC),
    toolSearchContainer: Color(0xFF463C51),
    onToolSearchContainer: Color(0xFFE4DDE9),
    toolFilesContainer: Color(0xFF3C4739),
    onToolFilesContainer: Color(0xFFDBE3D5),
    toolExtensionContainer: Color(0xFF404733),
    onToolExtensionContainer: Color(0xFFDCE2CC),
    toolGenericContainer: Color(0xFF454239),
    onToolGenericContainer: Color(0xFFF3EBDD),
  );

  @override
  PiColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? diffAddBg,
    Color? diffAddFg,
    Color? diffDelBg,
    Color? diffDelFg,
    Color? diffHunkFg,
    Color? codeWellBg,
    Color? codeWellFg,
    Color? codeWellBorder,
    Color? lineNumberFg,
    List<Color>? ansi,
    Color? toolTerminalContainer,
    Color? onToolTerminalContainer,
    Color? toolReadContainer,
    Color? onToolReadContainer,
    Color? toolEditContainer,
    Color? onToolEditContainer,
    Color? toolSearchContainer,
    Color? onToolSearchContainer,
    Color? toolFilesContainer,
    Color? onToolFilesContainer,
    Color? toolExtensionContainer,
    Color? onToolExtensionContainer,
    Color? toolGenericContainer,
    Color? onToolGenericContainer,
    List<Color>? identity,
    List<Color>? onIdentity,
  }) {
    return PiColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      diffAddBg: diffAddBg ?? this.diffAddBg,
      diffAddFg: diffAddFg ?? this.diffAddFg,
      diffDelBg: diffDelBg ?? this.diffDelBg,
      diffDelFg: diffDelFg ?? this.diffDelFg,
      diffHunkFg: diffHunkFg ?? this.diffHunkFg,
      codeWellBg: codeWellBg ?? this.codeWellBg,
      codeWellFg: codeWellFg ?? this.codeWellFg,
      codeWellBorder: codeWellBorder ?? this.codeWellBorder,
      lineNumberFg: lineNumberFg ?? this.lineNumberFg,
      ansi: ansi ?? this.ansi,
      identity: identity ?? this.identity,
      onIdentity: onIdentity ?? this.onIdentity,
      toolTerminalContainer:
          toolTerminalContainer ?? this.toolTerminalContainer,
      onToolTerminalContainer:
          onToolTerminalContainer ?? this.onToolTerminalContainer,
      toolReadContainer: toolReadContainer ?? this.toolReadContainer,
      onToolReadContainer: onToolReadContainer ?? this.onToolReadContainer,
      toolEditContainer: toolEditContainer ?? this.toolEditContainer,
      onToolEditContainer: onToolEditContainer ?? this.onToolEditContainer,
      toolSearchContainer: toolSearchContainer ?? this.toolSearchContainer,
      onToolSearchContainer:
          onToolSearchContainer ?? this.onToolSearchContainer,
      toolFilesContainer: toolFilesContainer ?? this.toolFilesContainer,
      onToolFilesContainer: onToolFilesContainer ?? this.onToolFilesContainer,
      toolExtensionContainer:
          toolExtensionContainer ?? this.toolExtensionContainer,
      onToolExtensionContainer:
          onToolExtensionContainer ?? this.onToolExtensionContainer,
      toolGenericContainer: toolGenericContainer ?? this.toolGenericContainer,
      onToolGenericContainer:
          onToolGenericContainer ?? this.onToolGenericContainer,
    );
  }

  @override
  PiColors lerp(PiColors? other, double t) {
    if (other is! PiColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return PiColors(
      success: mix(success, other.success),
      onSuccess: mix(onSuccess, other.onSuccess),
      successContainer: mix(successContainer, other.successContainer),
      onSuccessContainer: mix(onSuccessContainer, other.onSuccessContainer),
      warning: mix(warning, other.warning),
      onWarning: mix(onWarning, other.onWarning),
      warningContainer: mix(warningContainer, other.warningContainer),
      onWarningContainer: mix(onWarningContainer, other.onWarningContainer),
      diffAddBg: mix(diffAddBg, other.diffAddBg),
      diffAddFg: mix(diffAddFg, other.diffAddFg),
      diffDelBg: mix(diffDelBg, other.diffDelBg),
      diffDelFg: mix(diffDelFg, other.diffDelFg),
      diffHunkFg: mix(diffHunkFg, other.diffHunkFg),
      codeWellBg: mix(codeWellBg, other.codeWellBg),
      codeWellFg: mix(codeWellFg, other.codeWellFg),
      codeWellBorder: mix(codeWellBorder, other.codeWellBorder),
      lineNumberFg: mix(lineNumberFg, other.lineNumberFg),
      ansi: [for (var i = 0; i < ansi.length; i++) mix(ansi[i], other.ansi[i])],
      identity: [
        for (var i = 0; i < identity.length; i++)
          mix(identity[i], other.identity[i]),
      ],
      onIdentity: [
        for (var i = 0; i < onIdentity.length; i++)
          mix(onIdentity[i], other.onIdentity[i]),
      ],
      toolTerminalContainer: mix(
        toolTerminalContainer,
        other.toolTerminalContainer,
      ),
      onToolTerminalContainer: mix(
        onToolTerminalContainer,
        other.onToolTerminalContainer,
      ),
      toolReadContainer: mix(toolReadContainer, other.toolReadContainer),
      onToolReadContainer: mix(onToolReadContainer, other.onToolReadContainer),
      toolEditContainer: mix(toolEditContainer, other.toolEditContainer),
      onToolEditContainer: mix(onToolEditContainer, other.onToolEditContainer),
      toolSearchContainer: mix(toolSearchContainer, other.toolSearchContainer),
      onToolSearchContainer: mix(
        onToolSearchContainer,
        other.onToolSearchContainer,
      ),
      toolFilesContainer: mix(toolFilesContainer, other.toolFilesContainer),
      onToolFilesContainer: mix(
        onToolFilesContainer,
        other.onToolFilesContainer,
      ),
      toolExtensionContainer: mix(
        toolExtensionContainer,
        other.toolExtensionContainer,
      ),
      onToolExtensionContainer: mix(
        onToolExtensionContainer,
        other.onToolExtensionContainer,
      ),
      toolGenericContainer: mix(
        toolGenericContainer,
        other.toolGenericContainer,
      ),
      onToolGenericContainer: mix(
        onToolGenericContainer,
        other.onToolGenericContainer,
      ),
    );
  }
}
