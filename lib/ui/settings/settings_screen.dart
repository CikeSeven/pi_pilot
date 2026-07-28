import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../theme/semantic_colors.dart';
import 'settings_sections.dart';

/// 设置索引页。
///
/// 原来这是一个 832 行、滚动高度 ~2,100dp(约 3 屏)的单页,其中 448dp
/// 是纯分组标题留白,而且断开连接时两段会缩成空壳、页面长度悄悄变化。
/// 现在首屏就是 6 个入口,每个带一行当前值摘要,点进去是能一屏看完的子页。
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

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('设置')),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: SliverList.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = entries[index];
                // 每个入口一个专属身份色,列表一眼能分辨,不是一排一样的灰图标
                final slot = PiColors.identityIndex(entry.title);
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: piColors.identity[slot],
                      foregroundColor: piColors.onIdentity[slot],
                      child: Icon(entry.icon, size: 22),
                    ),
                    title: Text(entry.title),
                    subtitle: Text(
                      entry.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: entry.builder)),
                  ),
                );
              },
            ),
          ),
        ],
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
