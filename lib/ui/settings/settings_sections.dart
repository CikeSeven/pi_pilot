import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/background_permission.dart';
import '../../core/notification_service.dart';
import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../theme/shapes.dart';
import 'background_permission_guide.dart';
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
          const SizedBox(height: 12),
          // 聊天排版:字号/行距用户可调,预览卡实时反映。
          const _ChatTypographyCard(),
        ],
      ),
    );
  }
}

/// 聊天排版卡:字号缩放 + 行距滑杆,上方一段实时预览。
class _ChatTypographyCard extends ConsumerWidget {
  const _ChatTypographyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    final previewStyle = chatBodyStyle(context, settings);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('聊天排版', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            // 实时预览:边框围出一小段对话样张,调滑杆立刻看得到效果。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(PiShape.md),
              ),
              child: Text(
                '好的,我来处理。先查一下这个报错的原因,'
                '然后给补丁跑一轮验证,确认无回归后再交付。',
                style: previewStyle,
              ),
            ),
            const SizedBox(height: 16),
            _SliderRow(
              label: '字号',
              value: settings.chatFontScale,
              min: 0.85,
              max: 1.40,
              divisions: 11,
              display: '${(settings.chatFontScale * 100).round()}%',
              onChanged: (v) => notifier.setChatTypography(fontScale: v),
            ),
            _SliderRow(
              label: '行距',
              value: settings.chatLineHeight,
              min: 1.25,
              max: 2.00,
              divisions: 15,
              display: settings.chatLineHeight.toStringAsFixed(2),
              onChanged: (v) => notifier.setChatTypography(lineHeight: v),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => notifier.setChatTypography(
                  fontScale: 1.0,
                  lineHeight: 1.45,
                ),
                child: const Text('重置默认'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ],
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
                const _BackgroundPermissionTile(),
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

// ---------------------------------------------------------------------------
// 后台运行豁免
// ---------------------------------------------------------------------------

/// 后台运行豁免状态与引导入口。
///
/// 为什么值得单独占一个入口:真机实测(小米 13 / HyperOS V816 / Android 16)
/// 表明这是后台实时通知的**决定性变量**。未授予时应用退到后台约 60-90 秒即被
/// 系统整体冻结,前台服务不给豁免,冻结期间进程内一切都醒不过来;授予后同一
/// 场景下 5 分钟 7 条事件全部实时送达(延迟 7-43ms)。
///
/// 用户遇到「通知延迟」时第一时间会来通知设置页,所以入口放在这里而不是
/// 藏进关于页。
class _BackgroundPermissionTile extends StatefulWidget {
  const _BackgroundPermissionTile();

  @override
  State<_BackgroundPermissionTile> createState() =>
      _BackgroundPermissionTileState();
}

class _BackgroundPermissionTileState extends State<_BackgroundPermissionTile>
    with WidgetsBindingObserver {
  BackgroundPermissionStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户去系统设置改完开关会回到这里,必须重读状态,
    // 否则界面停留在旧结论、看起来像没生效。
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final status = await NotificationService.instance
        .readBackgroundPermissionState();
    if (!mounted) return;
    setState(() => _status = status);
  }

  void _showGuide() {
    final status = _status;
    if (status == null) return;
    showBackgroundPermissionGuide(context, status);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    // 非 Android 或读取失败:不显示这一项,避免出现无法操作的死入口。
    if (status == null ||
        status.verdict == BackgroundPermissionVerdict.unknown) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final ok = status.verdict == BackgroundPermissionVerdict.unrestricted;
    final color = ok ? theme.colorScheme.primary : theme.colorScheme.error;

    return ListTile(
      leading: Icon(
        ok ? Icons.battery_saver : Icons.battery_alert_outlined,
        color: color,
      ),
      title: const Text('后台运行'),
      subtitle: Text(status.summary),
      trailing: ok
          ? Icon(Icons.check_circle_outline, color: color)
          : const Icon(Icons.chevron_right),
      // 不自动跳转:实测各厂商 deeplink 组件名极不稳定(HyperOS V816
      // 已移除整套 HiddenApps 组件),没有任何可靠的直达路径,
      // 统一改为纯文字引导,让用户按步骤自己去系统设置里改。
      onTap: _showGuide,
    );
  }
}
