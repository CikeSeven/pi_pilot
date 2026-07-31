import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notification_service.dart';
import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import 'settings_widgets.dart';

/// 设置的 5 个子页。
///
/// 原来这些全挤在一个 2,100dp(约 3 屏)的单页里,其中 448dp 是纯分组标题
/// 留白。拆成子页之后首屏只剩 6 个入口,每页都能一屏看完。

// ---------------------------------------------------------------------------
// 外观
// ---------------------------------------------------------------------------

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AccentPicker(current: settings.accent),
                  const SizedBox(height: 24),
                  Text('明暗模式', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 12),
                  // 纯文字三段:icon+label 在窄屏/大字体下会把 SegmentedButton
                  // 的内部 Row 顶破(RenderFlex 溢出),文字本身已足够清楚
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                      ButtonSegment(value: ThemeMode.system, label: Text('跟随')),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (selection) => ref
                        .read(settingsProvider.notifier)
                        .setThemeMode(selection.first),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 通知与快捷指令
// ---------------------------------------------------------------------------

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('通知与快捷指令')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('后台通知'),
                  subtitle: const Text('任务完成或等待输入时提醒'),
                  value: settings.notificationsEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setNotificationsEnabled(value),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.vibration),
                  title: const Text('震动'),
                  subtitle: const Text('任务提醒到达时震动'),
                  value: settings.notificationVibrationEnabled,
                  onChanged: settings.notificationsEnabled
                      ? (value) => ref
                            .read(settingsProvider.notifier)
                            .setNotificationVibrationEnabled(value)
                      : null,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('系统通知设置'),
                  subtitle: const Text('管理悬浮通知、声音与锁屏显示'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => NotificationService.instance
                      .openSystemNotificationSettings(
                        vibrate: settings.notificationVibrationEnabled,
                      ),
                ),
                const Divider(height: 1),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: QuickPromptsEditor(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 模型与行为
// ---------------------------------------------------------------------------

class BehaviorPage extends ConsumerStatefulWidget {
  const BehaviorPage({super.key});

  @override
  ConsumerState<BehaviorPage> createState() => _BehaviorPageState();
}

class _BehaviorPageState extends ConsumerState<BehaviorPage> {
  int _revision = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('模型与行为')),
      body: ListView(
        key: ValueKey(_revision),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ModelBehaviorCard(onChanged: () => setState(() => _revision++)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 当前会话
// ---------------------------------------------------------------------------

class SessionInfoPage extends ConsumerStatefulWidget {
  const SessionInfoPage({super.key});

  @override
  ConsumerState<SessionInfoPage> createState() => _SessionInfoPageState();
}

class _SessionInfoPageState extends ConsumerState<SessionInfoPage> {
  SessionStats? _stats;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (ref.read(piSessionProvider).status != PiConnStatus.connected) {
      if (mounted) setState(() => _stats = null);
      return;
    }
    final stats = await ref.read(piSessionNotifierProvider)?.getSessionStats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('当前会话')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [SessionInfoCard(stats: _stats, onRefresh: _load)],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 关于
// ---------------------------------------------------------------------------

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.hub_outlined),
                  title: Text('连接方式'),
                  subtitle: Text('手机通过 bridge 连接电脑上的 pi'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.terminal),
                  title: const Text('bridge 启动'),
                  subtitle: Text(
                    '电脑上运行:cd bridge && npm start',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
