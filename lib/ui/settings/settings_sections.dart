import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_models.dart';
import '../../core/notification_service.dart';
import '../../core/p2p_signaling.dart';
import '../../core/pi_connection.dart';
import '../../state/device_manager.dart';
import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import 'settings_widgets.dart';

/// 设置的 6 个子页。
///
/// 原来这些全挤在一个 2,100dp(约 3 屏)的单页里,其中 448dp 是纯分组标题
/// 留白。拆成子页之后首屏只剩 6 个入口,每页都能一屏看完。

// ---------------------------------------------------------------------------
// 连接
// ---------------------------------------------------------------------------

class ConnectionPage extends ConsumerStatefulWidget {
  const ConnectionPage({super.key});

  @override
  ConsumerState<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends ConsumerState<ConnectionPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '9377');
  final _token = TextEditingController();
  final _p2pKey = GlobalKey<_P2pCardState>();
  bool _obscure = true;
  bool _filled = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _fillFromSettings(AppSettings settings) {
    if (_filled || !settings.loaded) return;
    _filled = true;
    _host.text = settings.host;
    _port.text = '${settings.port}';
    _token.text = settings.token;
  }

  Future<void> _saveAndConnect() async {
    // 兼容误粘贴完整 URL(http://host:port/path),自动纠正输入框
    final parsed = parseHostInput(_host.text);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '主机地址格式不正确,示例:192.168.1.100 或 http://192.168.1.100:9377',
          ),
        ),
      );
      return;
    }
    _host.text = parsed.host;
    if (parsed.port != null) _port.text = '${parsed.port}';
    final port = int.tryParse(_port.text.trim()) ?? 9377;
    final p2pSaved = await _p2pKey.currentState?.save(showNotice: false);
    if (p2pSaved == false) return;
    await ref
        .read(settingsProvider.notifier)
        .setConnection(
          host: parsed.host,
          port: port,
          token: _token.text.trim(),
        );
    // 连接配置升级为 roster 设备:地址命中的复用原 id,并**保留它已有的
    // transport / P2P 三要素 / lastHubId**。设置页是旧版单设备表单,它的
    // P2P 卡为空不代表「清空这台设备的 P2P」——否则在设备卡上配好的 P2P
    // 会被这里静默抹掉(「重开应用后 P2P 配置全消失」的根源)。只有设置页
    // P2P 四要素齐备时,才视为用户明确要用设置页的值覆盖。
    // upsertDevice 会让它成为激活设备并按新配置重连。
    final settings = ref.read(settingsProvider);
    final manager = ref.read(deviceManagerProvider);
    final hit = manager.devices
        .where((d) => d.host == parsed.host && d.port == port)
        .firstOrNull;
    final useSettingsP2p = settings.hasP2p;
    await ref
        .read(deviceManagerProvider.notifier)
        .upsertDevice(
          DeviceProfile(
            id: hit?.id ?? generateDeviceId(),
            name: hit?.name ?? parsed.host,
            host: parsed.host,
            port: port,
            token: _token.text.trim(),
            transport: useSettingsP2p
                ? DeviceTransport.auto
                : (hit?.transport ?? DeviceTransport.lan),
            p2pRendezvous: useSettingsP2p
                ? settings.p2pRendezvous
                : hit?.p2pRendezvous,
            p2pDeviceId: useSettingsP2p
                ? settings.p2pDeviceId
                : hit?.p2pDeviceId,
            p2pSecret: useSettingsP2p ? settings.p2pSecret : hit?.p2pSecret,
            lastHubId: hit?.lastHubId,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    _fillFromSettings(settings);
    final status = ref.watch(piSessionProvider.select((s) => s.status));

    return Scaffold(
      appBar: AppBar(title: const Text('连接')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatusRow(status: status),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: '主机',
                      hintText: '192.168.1.100',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      prefixIcon: Icon(Icons.numbers),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _token,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Token',
                      prefixIcon: const Icon(Icons.key_outlined),
                      suffixIcon: IconButton(
                        tooltip: _obscure ? '显示' : '隐藏',
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _saveAndConnect,
                    icon: const Icon(Icons.link),
                    label: const Text('保存并连接'),
                  ),
                  if (status == PiConnStatus.connected) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(piSessionNotifierProvider)?.disconnect(),
                      icon: const Icon(Icons.link_off),
                      label: const Text('断开'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _P2pCard(key: _p2pKey),
          const SizedBox(height: 12),
          const HubSourceCard(),
        ],
      ),
    );
  }
}

/// 远程打洞(P2P)配置卡:开关 + 信令服地址/设备名/配对密钥。
/// 卡内按钮可单独保存;页面的“保存并连接”也会一起持久化这些字段。
class _P2pCard extends ConsumerStatefulWidget {
  const _P2pCard({super.key});

  @override
  ConsumerState<_P2pCard> createState() => _P2pCardState();
}

class _P2pCardState extends ConsumerState<_P2pCard> {
  final _rendezvous = TextEditingController();
  final _deviceId = TextEditingController();
  final _secret = TextEditingController();
  bool _enabled = false;
  bool _obscure = true;
  bool _filled = false;

  @override
  void dispose() {
    _rendezvous.dispose();
    _deviceId.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _fillFromSettings(AppSettings settings) {
    if (_filled || !settings.loaded) return;
    _filled = true;
    _enabled = settings.p2pEnabled;
    _rendezvous.text = settings.p2pRendezvous;
    _deviceId.text = settings.p2pDeviceId;
    _secret.text = settings.p2pSecret;
  }

  Future<bool> save({bool showNotice = true}) async {
    final rendezvous = normalizeP2pSignalingUrl(_rendezvous.text);
    final deviceId = _deviceId.text.trim();
    final secret = _secret.text;
    if (_enabled && !isAllowedP2pSignalingUrl(rendezvous)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('公网信令必须使用 wss://,ws:// 仅限本机测试')),
        );
      }
      return false;
    }
    if (_enabled && !isValidP2pDeviceId(deviceId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备名需为 3-64 位,仅限英文字母、数字、点、下划线和连字符')),
        );
      }
      return false;
    }
    if (_enabled && !isValidP2pPairingKey(secret)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('配对 Key 需为 16-128 位可打印 ASCII,且至少包含大小写、数字、符号中的三类'),
          ),
        );
      }
      return false;
    }
    await ref
        .read(settingsProvider.notifier)
        .setP2pConfig(
          enabled: _enabled,
          rendezvous: rendezvous,
          deviceId: deviceId,
          secret: secret,
        );
    if (showNotice && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('打洞配置已保存,下次连接生效')));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    _fillFromSettings(settings);
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.cell_tower_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('远程打洞(P2P)', style: theme.textTheme.titleMedium),
                ),
                Switch(
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '只需填写信令域名,会自动使用 WSS;手机与电脑填写相同设备名和配对 Key 即可连接。'
              'DataChannel 内容由 DTLS 加密,后台通知暂不支持 P2P。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _rendezvous,
              decoration: const InputDecoration(
                labelText: '信令服地址',
                hintText: kDefaultRendezvousAddress,
                prefixIcon: Icon(Icons.hub_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceId,
              decoration: const InputDecoration(
                labelText: '设备名',
                hintText: '与 bridge 的设备名一致',
                prefixIcon: Icon(Icons.computer_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _secret,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '配对密钥',
                hintText: '与 bridge 填写相同的 Key,无需在信令服预注册',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示' : '隐藏',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => save(),
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存打洞配置'),
            ),
          ],
        ),
      ),
    );
  }
}

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
