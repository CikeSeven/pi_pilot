import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../theme/paper.dart';
import '../theme/semantic_colors.dart';
import '../theme/shapes.dart';
import '../theme/typography.dart';
import 'settings_sections.dart';

/// 设置索引页:**衬线页头 + 编辑式分组卡**。
///
/// Editorial Retro 改版。设计规范说设置页「最容易出效果」,因为它天然适合
/// 大留白 + 整齐卡片 + 标签化图标 + 分组信息——像一本优雅杂志的目录页。
///
/// 结构:衬线大标题「设置」+ 品牌印章 → 栏目名 → 6 张描边纸卡入口,
/// 每张带一枚复古色圆形图标和一行当前值摘要。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final piState = ref.watch(piSessionProvider);
    final piColors = PiColors.of(context);

    String connectionSummary() => switch (piState.status) {
      PiConnStatus.connected => '已连接 · ${settings.host}:${settings.port}',
      PiConnStatus.connecting => '正在连接…',
      PiConnStatus.failed => '连接失败',
      _ => settings.hasConnection ? '${settings.host}:${settings.port}' : '未配置',
    };

    final entries = <_SettingsEntry>[
      _SettingsEntry(
        icon: Icons.link,
        title: '连接',
        summary: connectionSummary(),
        builder: (_) => const ConnectionPage(),
      ),
      _SettingsEntry(
        icon: Icons.palette_outlined,
        title: '外观',
        summary:
            '${settings.accent.label} · ${switch (settings.themeMode) {
              ThemeMode.light => '浅色',
              ThemeMode.dark => '深色',
              ThemeMode.system => '跟随系统',
            }}',
        builder: (_) => const AppearancePage(),
      ),
      _SettingsEntry(
        icon: Icons.notifications_outlined,
        title: '通知与快捷指令',
        summary: settings.notificationsEnabled
            ? '通知已开启 · ${settings.quickPrompts.length} 条快捷指令'
            : '通知已关闭 · ${settings.quickPrompts.length} 条快捷指令',
        builder: (_) => const NotificationsPage(),
      ),
      _SettingsEntry(
        icon: Icons.tune,
        title: '模型与行为',
        summary: piState.status == PiConnStatus.connected
            ? [?piState.modelName, ?piState.thinkingLevel].join(' · ')
            : '连接后可配置',
        builder: (_) => const BehaviorPage(),
      ),
      _SettingsEntry(
        icon: Icons.analytics_outlined,
        title: '当前会话',
        summary: piState.sessionName ?? piState.cwd ?? '未选择会话',
        builder: (_) => const SessionInfoPage(),
      ),
      _SettingsEntry(
        icon: Icons.info_outline,
        title: '关于',
        summary: 'PiPilot · 手机远程驾驶 pi',
        builder: (_) => const AboutPage(),
      ),
    ];

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    // 这个页面**两用**:既作底栏的「设置」tab(外层 AppShell 已给背景),
    // 又会被 Navigator.push 成独立路由(会话页「前往设置」、抽屉入口)。
    // 透明 Scaffold 在 tab 模式下能透出外层背景,但 push 成独立路由时
    // 下面没有 BackdropPaper,会透出 MaterialApp 默认底色 → 黑白混搭。
    // 所以这里自己套一层 BackdropPaper,两种场景都自带正确背景。
    return Scaffold(
      body: BackdropPaper(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
            children: [
              // 页头:衬线大标题 + 品牌印章,像刊物目录页的报头
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '设置',
                          style: AppType.displayTitle(
                            size: 32,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '连接、外观、行为与会话',
                          style: AppType.serifItalic(
                            size: 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 矢量小装饰替代带白底的印章 PNG
                  EditorialOrnament(
                    size: 54,
                    color: colors.onSurfaceVariant,
                    accent: colors.primary,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Eyebrow(text: '目录', withRule: true),
              const SizedBox(height: 14),
              for (final entry in entries) ...[
                _SettingsCard(entry: entry, piColors: piColors),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              // 页脚:一条编辑式短线收住整页(替代带白底的叶枝 PNG)
              Center(
                child: SizedBox(
                  width: 64,
                  child: EditorialRule(color: colors.outlineVariant),
                ),
              ),
            ],
          ),
        ),
      ),
      );
  }
}

class _SettingsEntry {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.summary,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String summary;
  final WidgetBuilder builder;
}

/// 设置入口纸卡:复古色圆形图标 + 标题 + 当前值摘要。
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.entry, required this.piColors});

  final _SettingsEntry entry;
  final PiColors piColors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // 每个入口一个专属身份色,列表一眼能分辨,不是一排一样的灰图标
    final slot = PiColors.identityIndex(entry.title);

    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: entry.builder)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
          child: Row(
            children: [
              // 圆形复古色图标区(设计规范:「柔和色彩的圆形图标区域」)
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: piColors.identity[slot],
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: piColors.onIdentity[slot].withValues(alpha: 0.18),
                  ),
                ),
                child: Icon(
                  entry.icon,
                  size: 21,
                  color: piColors.onIdentity[slot],
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
