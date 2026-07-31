import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../common/tokens.dart';
import '../../theme/highlight_theme.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/typography.dart';

/// 超过该长度不做语法高亮(纯 mono 渲染),避免大输出卡顿。
const _kHighlightMaxChars = 20000;

final Highlight _hl = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'go': langGo,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'markdown': langMarkdown,
    'python': langPython,
    'rust': langRust,
    'sql': langSql,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

const _aliases = <String, String>{
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'node': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'sh': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'shell': 'bash',
  'console': 'bash',
  'yml': 'yaml',
  'html': 'xml',
  'htm': 'xml',
  'svg': 'xml',
  'c++': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'h': 'c',
  'hpp': 'cpp',
  'rs': 'rust',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'md': 'markdown',
  'patch': 'diff',
};

String? _normalizeLanguage(String? language) {
  if (language == null) return null;
  final lower = language.trim().toLowerCase();
  if (lower.isEmpty) return null;
  final resolved = _aliases[lower] ?? lower;
  return _hl.listLanguages().contains(resolved) ? resolved : null;
}

/// 按文件扩展名推断高亮语言;未知返回 null。
String? languageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  return _normalizeLanguage(path.substring(dot + 1));
}

/// 语法高亮为 TextSpan;语言未知或超长时退化为纯文本 span。
TextSpan highlightCode(
  String code,
  String? language,
  Brightness brightness, {
  TextStyle? style,
}) {
  final base = style ?? AppType.mono();
  final lang = _normalizeLanguage(language);
  if (lang == null || code.length > _kHighlightMaxChars) {
    return TextSpan(text: code, style: base);
  }
  try {
    final result = _hl.highlight(code: code, language: lang);
    final renderer = TextSpanRenderer(base, piHighlightTheme(brightness));
    result.render(renderer);
    return renderer.span ?? TextSpan(text: code, style: base);
  } catch (_) {
    return TextSpan(text: code, style: base);
  }
}

/// 终端风代码块:语言标签 + 复制按钮 + 横向滚动代码井,可选行号。
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.showLineNumbers = false,
    this.firstLineNumber = 1,
    this.maxHeight,
    this.embedded = false,
  });

  final String code;
  final String? language;
  final bool showLineNumbers;
  final int firstLineNumber;
  final double? maxHeight;

  /// 嵌入在工具卡片内部时:去掉边框、背景、语言标签行,只留代码内容。
  /// 工具卡片本身已有边框和背景,再套一层就是「框中框」。
  final bool embedded;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  TextSpan? _span;
  String? _cachedCode;
  String? _cachedLanguage;
  Brightness? _cachedBrightness;

  String get _trimmedCode {
    var code = widget.code;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return code;
  }

  /// 复制成功后,复制键图标闪成对勾再回退 —— 替代之前的 SnackBar。
  /// SnackBar 会从底部弹一条横幅打断阅读,对「复制」这种轻操作太重;
  /// 原地闪对勾是即时、就地、不打扰的反馈。
  bool _copied = false;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.lightImpact();
    setState(() => _copied = true);
    // 1.2s 后回退成复制图标。用 timer 而不是 AnimatedSwitcher 的自带反转,
    // 因为这里要的是一个明确的「闪一下」节奏,不是悬停态。
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final piColors = PiColors.of(context);
    final brightness = Theme.of(context).brightness;
    final code = _trimmedCode;

    if (_span == null ||
        _cachedCode != code ||
        _cachedLanguage != widget.language ||
        _cachedBrightness != brightness) {
      _span = highlightCode(code, widget.language, brightness);
      _cachedCode = code;
      _cachedLanguage = widget.language;
      _cachedBrightness = brightness;
    }

    final lineCount = '\n'.allMatches(code).length + 1;
    Widget body = SelectableText.rich(_span!);
    if (widget.showLineNumbers) {
      final gutter = List.generate(
        lineCount,
        (i) => '${widget.firstLineNumber + i}',
      ).join('\n');
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            gutter,
            textAlign: TextAlign.right,
            style: AppType.mono(color: piColors.lineNumberFg),
          ),
          const SizedBox(width: 16),
          body,
        ],
      );
    }
    body = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: body,
    );
    if (widget.maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: SingleChildScrollView(child: body),
      );
    }

    // 嵌入模式:工具卡片内部,不画边框/背景/标签行,直接出代码。
    if (widget.embedded) return body;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: piColors.codeWellBg,
        borderRadius: BorderRadius.circular(PiShape.sm),
        border: Border.all(color: piColors.codeWellBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            // 40 而不是 32:里面有一个 IconButton,32 会把它的命中区压扁
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 14),
                // 语言串来自 markdown 围栏信息,可能是 ```json title="…很长…"
                Expanded(
                  child: Text(
                    widget.language?.isNotEmpty == true
                        ? widget.language!
                        : 'text',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoLabel(color: colors.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  tooltip: '复制',
                  // 复制成功:图标变对勾 + 主色,带一次缩放过渡。
                  style: IconButton.styleFrom(
                    foregroundColor: _copied
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) {
                      final t = anim.value;
                      // 进:从 60% 放大 + 淡入;退:缩小淡出
                      final scale = 0.6 + 0.4 * t;
                      return Opacity(
                        opacity: t,
                        child: Transform.scale(scale: scale, child: child),
                      );
                    },
                    child: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_outlined,
                      key: ValueKey(_copied),
                    ),
                  ),
                  onPressed: _copied ? null : () => _copy(context),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: piColors.codeWellBorder),
          body,
        ],
      ),
    );
  }
}
