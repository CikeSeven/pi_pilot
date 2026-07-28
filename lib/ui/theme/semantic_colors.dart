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
    success: Color(0xFF146B32),
    onSuccess: Color(0xFFFFFFFF),
    successContainer: Color(0xFFA6F2BC),
    onSuccessContainer: Color(0xFF00210B),
    warning: Color(0xFF7A5300),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFDEA6),
    onWarningContainer: Color(0xFF271900),
    diffAddBg: Color(0xFFD7F5DF),
    diffAddFg: Color(0xFF146B32),
    diffDelBg: Color(0xFFFCDAD6),
    diffDelFg: Color(0xFFB3261E),
    diffHunkFg: Color(0xFF4A5CC7),
    codeWellBg: Color(0xFFF4F3F8),
    codeWellFg: Color(0xFF1B1B1F),
    codeWellBorder: Color(0xFFE3E1E9),
    lineNumberFg: Color(0xFF7C7C87),
    ansi: [
      Color(0xFF1B1B1F),
      Color(0xFFB3261E),
      Color(0xFF146B32),
      Color(0xFF7A5300),
      Color(0xFF3B4FC4),
      Color(0xFF7B3FA0),
      Color(0xFF00637E),
      Color(0xFF5E5E68),
      Color(0xFF6E6E79),
      Color(0xFFC4291F),
      Color(0xFF1E7F3C),
      Color(0xFF8F6400),
      Color(0xFF4A5CC7),
      Color(0xFF8F4DB5),
      Color(0xFF00768F),
      Color(0xFF3C3C46),
    ],
    identity: [
      Color(0xFFD6E3FF), // 蓝
      Color(0xFFE0E0FF), // 靛
      Color(0xFFF4D9FF), // 紫
      Color(0xFFFFD8E8), // 粉
      Color(0xFFFFDAD5), // 珊瑚
      Color(0xFFFFDEA6), // 琥珀
      Color(0xFFA6F2BC), // 绿
      Color(0xFFBEEBFF), // 青
    ],
    onIdentity: [
      Color(0xFF00174B),
      Color(0xFF1B1B70),
      Color(0xFF2E004E),
      Color(0xFF3E001D),
      Color(0xFF410002),
      Color(0xFF271900),
      Color(0xFF00210B),
      Color(0xFF001E2B),
    ],
    toolTerminalContainer: Color(0xFFE0E0FF),
    onToolTerminalContainer: Color(0xFF1B1B70),
    toolReadContainer: Color(0xFFD6E3FF),
    onToolReadContainer: Color(0xFF00174B),
    toolEditContainer: Color(0xFFFFDEA6),
    onToolEditContainer: Color(0xFF271900),
    toolSearchContainer: Color(0xFFF4D9FF),
    onToolSearchContainer: Color(0xFF2E004E),
    toolFilesContainer: Color(0xFFBEEBFF),
    onToolFilesContainer: Color(0xFF001E2B),
    toolExtensionContainer: Color(0xFFA6F2BC),
    onToolExtensionContainer: Color(0xFF00210B),
    toolGenericContainer: Color(0xFFE3E1E9),
    onToolGenericContainer: Color(0xFF1B1B1F),
  );

  static const dark = PiColors(
    success: Color(0xFF7BDC9A),
    onSuccess: Color(0xFF00391A),
    successContainer: Color(0xFF005222),
    onSuccessContainer: Color(0xFFA6F2BC),
    warning: Color(0xFFF5BE48),
    onWarning: Color(0xFF3F2E00),
    warningContainer: Color(0xFF5B3F00),
    onWarningContainer: Color(0xFFFFDEA6),
    diffAddBg: Color(0xFF12301C),
    diffAddFg: Color(0xFF7BDC9A),
    diffDelBg: Color(0xFF3A1512),
    diffDelFg: Color(0xFFFFB4AB),
    diffHunkFg: Color(0xFFAEB9FF),
    codeWellBg: Color(0xFF0E0E12),
    codeWellFg: Color(0xFFE5E1E9),
    codeWellBorder: Color(0xFF2C2A31),
    lineNumberFg: Color(0xFF75757F),
    ansi: [
      Color(0xFF8E8E99),
      Color(0xFFFFB4AB),
      Color(0xFF7BDC9A),
      Color(0xFFF5BE48),
      Color(0xFFAEB9FF),
      Color(0xFFE9B3FF),
      Color(0xFF7BD5F0),
      Color(0xFFC9C6D0),
      Color(0xFFB0AFBA),
      Color(0xFFFFD2CD),
      Color(0xFFA8F0BE),
      Color(0xFFFFDEA6),
      Color(0xFFCBD2FF),
      Color(0xFFF4D9FF),
      Color(0xFFBEEBFF),
      Color(0xFFFFFFFF),
    ],
    identity: [
      Color(0xFF274777), // 蓝
      Color(0xFF31318E), // 靛
      Color(0xFF5A2B7A), // 紫
      Color(0xFF7B2949), // 粉
      Color(0xFF8C1D18), // 珊瑚
      Color(0xFF5B3F00), // 琥珀
      Color(0xFF005222), // 绿
      Color(0xFF004C63), // 青
    ],
    onIdentity: [
      Color(0xFFD6E3FF),
      Color(0xFFE0E0FF),
      Color(0xFFF4D9FF),
      Color(0xFFFFD8E8),
      Color(0xFFFFDAD5),
      Color(0xFFFFDEA6),
      Color(0xFFA6F2BC),
      Color(0xFFBEEBFF),
    ],
    toolTerminalContainer: Color(0xFF31318E),
    onToolTerminalContainer: Color(0xFFE0E0FF),
    toolReadContainer: Color(0xFF274777),
    onToolReadContainer: Color(0xFFD6E3FF),
    toolEditContainer: Color(0xFF5B3F00),
    onToolEditContainer: Color(0xFFFFDEA6),
    toolSearchContainer: Color(0xFF5A2B7A),
    onToolSearchContainer: Color(0xFFF4D9FF),
    toolFilesContainer: Color(0xFF004C63),
    onToolFilesContainer: Color(0xFFBEEBFF),
    toolExtensionContainer: Color(0xFF005222),
    onToolExtensionContainer: Color(0xFFA6F2BC),
    toolGenericContainer: Color(0xFF46464F),
    onToolGenericContainer: Color(0xFFE5E1E9),
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
