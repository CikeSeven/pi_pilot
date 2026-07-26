import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pi_connection.dart';
import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../main_shell.dart';

/// 设置页:连接配置、外观主题。模型/行为/统计在 P5 补全。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '9377');
  final _token = TextEditingController();
  bool _obscure = true;
  bool _filled = false;
  SessionStats? _stats;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPiData());
  }

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
            '主机地址格式不正确,示例:10.183.39.204 或 http://10.183.39.204:9377',
          ),
        ),
      );
      return;
    }
    _host.text = parsed.host;
    if (parsed.port != null) _port.text = '${parsed.port}';
    final port = int.tryParse(_port.text.trim()) ?? 9377;
    final token = _token.text.trim();
    await ref
        .read(settingsProvider.notifier)
        .setConnection(host: parsed.host, port: port, token: token);
    await ref.read(piSessionProvider.notifier).connect();
  }

  Future<void> _loadPiData() async {
    if (ref.read(piSessionProvider).status != PiConnStatus.connected) {
      if (mounted) setState(() => _stats = null);
      return;
    }
    final stats = await ref.read(piSessionProvider.notifier).getSessionStats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(piSessionProvider.select((s) => s.status), (_, next) {
      if (next == PiConnStatus.connected) _loadPiData();
    });
    ref.listen(piSessionProvider.select((s) => s.sessionId), (_, _) {
      _loadPiData();
    });
    final settings = ref.watch(settingsProvider);
    _fillFromSettings(settings);
    final status = ref.watch(piSessionProvider.select((s) => s.status));
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _SectionHeader(title: '连接', icon: Icons.link),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _StatusRow(status: status),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _host,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '主机',
                      hintText: '192.168.x.x 或 Tailscale 主机名',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      prefixIcon: Icon(Icons.numbers),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _token,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Token',
                      prefixIcon: const Icon(Icons.key_outlined),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
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
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: status == PiConnStatus.connecting
                              ? null
                              : _saveAndConnect,
                          icon: const Icon(Icons.link),
                          label: const Text('保存并连接'),
                        ),
                      ),
                      if (status == PiConnStatus.connected) ...[
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () =>
                              ref.read(piSessionProvider.notifier).disconnect(),
                          icon: const Icon(Icons.link_off),
                          label: const Text('断开'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          _SectionHeader(title: 'Source', icon: Icons.hub_outlined),
          const _HubSourceCard(),
          _SectionHeader(title: '外观', icon: Icons.palette_outlined),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('主题模式', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_outlined),
                          label: Text('浅色'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_outlined),
                          label: Text('深色'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          icon: Icon(Icons.settings_suggest_outlined),
                          label: Text('跟随系统'),
                        ),
                      ],
                      selected: {settings.themeMode},
                      onSelectionChanged: (modes) => ref
                          .read(settingsProvider.notifier)
                          .setThemeMode(modes.first),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _SectionHeader(title: '模型与行为', icon: Icons.tune),
          _ModelBehaviorCard(onChanged: _loadPiData),
          _SectionHeader(title: '当前会话', icon: Icons.analytics_outlined),
          _SessionInfoCard(stats: _stats, onRefresh: _loadPiData),
          _SectionHeader(title: '关于', icon: Icons.info_outline),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.hub_outlined),
                  title: Text('连接方式'),
                  subtitle: Text(
                    'App → Source Hub → desktop TUI / headless RPC',
                  ),
                ),
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
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _HubSourceCard extends ConsumerWidget {
  const _HubSourceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piState = ref.watch(piSessionProvider);
    final source = piState.selectedSource;
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              source?.isDesktop == true
                  ? Icons.desktop_windows_outlined
                  : Icons.dns_outlined,
              color: source?.connected == true
                  ? colors.primary
                  : colors.outline,
            ),
            title: Text(source?.label ?? '未选择 source'),
            subtitle: Text(
              source == null
                  ? '${piState.sources.where((item) => item.connected).length} 个在线 source'
                  : '${source.isDesktop ? '桌面 TUI' : 'Headless RPC'} · ${source.connected ? '在线' : '离线'} · ${piState.ownsSource ? '控制者' : '观察者'}',
            ),
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () =>
                    ref.read(selectedTabProvider.notifier).select(1),
                icon: const Icon(Icons.list, size: 18),
                label: const Text('管理 source'),
              ),
              if (source != null && (source.connected || source.isHeadless))
                TextButton.icon(
                  onPressed: source.ownerPresent && !piState.ownsSource
                      ? null
                      : () async {
                          if (piState.ownsSource) {
                            await ref
                                .read(piSessionProvider.notifier)
                                .releaseControl();
                          } else {
                            await ref
                                .read(piSessionProvider.notifier)
                                .acquireControl();
                          }
                        },
                  icon: Icon(
                    piState.ownsSource
                        ? Icons.lock_outline
                        : Icons.touch_app_outlined,
                    size: 18,
                  ),
                  label: Text(piState.ownsSource ? '释放控制' : '接管控制'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.primary),
          const SizedBox(width: 6),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.primary),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status});

  final PiConnStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (status) {
      PiConnStatus.connected => (Icons.check_circle, '已连接', Colors.green),
      PiConnStatus.connecting => (Icons.sync, '连接中…', colors.tertiary),
      PiConnStatus.failed => (Icons.error, '连接失败', colors.error),
      PiConnStatus.disconnected => (Icons.link_off, '未连接', colors.outline),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

String _fmtTokens(int? v) {
  if (v == null) return '-';
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

/// 模型选择、思考档位、auto-compaction / auto-retry 开关。
class _ModelBehaviorCard extends ConsumerStatefulWidget {
  const _ModelBehaviorCard({required this.onChanged});

  /// Called after a change that may affect session stats.
  final VoidCallback onChanged;

  @override
  ConsumerState<_ModelBehaviorCard> createState() => _ModelBehaviorCardState();
}

class _ModelBehaviorCardState extends ConsumerState<_ModelBehaviorCard> {
  List<ModelInfo>? _models;
  List<String>? _levels;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (ref.read(piSessionProvider).status != PiConnStatus.connected) {
      if (mounted) {
        setState(() {
          _models = null;
          _levels = null;
        });
      }
      return;
    }
    setState(() => _loading = true);
    final notifier = ref.read(piSessionProvider.notifier);
    final models = await notifier.getAvailableModels();
    final levels = await notifier.getThinkingLevels();
    if (!mounted) return;
    setState(() {
      _models = models;
      _levels = levels;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(piSessionProvider.select((s) => s.status), (_, next) {
      if (next == PiConnStatus.connected) _load();
    });
    final piState = ref.watch(piSessionProvider);
    final autoRetry = ref.watch(settingsProvider.select((s) => s.autoRetry));
    final colors = Theme.of(context).colorScheme;
    final notifier = ref.read(piSessionProvider.notifier);
    final source = piState.selectedSource;
    final connected =
        piState.status == PiConnStatus.connected && source?.connected == true;
    final canControl = piState.canControl;

    if (!connected) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Icon(Icons.cloud_off_outlined, color: colors.outline),
          title: const Text('未连接'),
          subtitle: const Text('连接后可配置模型与行为'),
        ),
      );
    }

    final models = _models;
    final levels = _levels;
    final currentModelKey = models
        ?.where((m) => m.id == piState.modelId)
        .firstOrNull
        ?.key;
    final currentLevel =
        (levels != null && levels.contains(piState.thinkingLevel))
        ? piState.thinkingLevel
        : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            DropdownButtonFormField<String>(
              initialValue: currentModelKey,
              decoration: const InputDecoration(
                labelText: '模型',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.smart_toy_outlined),
              ),
              items: [
                for (final m in models ?? const <ModelInfo>[])
                  DropdownMenuItem(
                    value: m.key,
                    child: Text(
                      '${m.name} · ${m.provider}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged:
                  models == null ||
                      !canControl ||
                      source?.supports('set_model') != true
                  ? null
                  : (key) async {
                      final m = models.firstWhere((x) => x.key == key);
                      final ok = await notifier.setModel(m.provider, m.id);
                      if (ok) widget.onChanged();
                    },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: currentLevel,
              decoration: const InputDecoration(
                labelText: '思考档位',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.psychology_outlined),
              ),
              items: [
                for (final l in levels ?? const <String>[])
                  DropdownMenuItem(value: l, child: Text(l)),
              ],
              onChanged:
                  levels == null ||
                      !canControl ||
                      source?.supports('set_thinking_level') != true
                  ? null
                  : (level) async {
                      if (level != null) {
                        await notifier.setThinkingLevel(level);
                      }
                    },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动压缩上下文'),
              subtitle: const Text('上下文接近上限时自动 compact'),
              value: piState.autoCompactionEnabled,
              onChanged: canControl && source?.isHeadless == true
                  ? (v) => notifier.setAutoCompaction(v)
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动重试'),
              subtitle: const Text('限流 / 5xx 等瞬时错误自动重试'),
              value: autoRetry,
              onChanged: canControl && source?.isHeadless == true
                  ? (v) => notifier.setAutoRetry(v)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前会话信息 + token 统计 + 导出 HTML。
class _SessionInfoCard extends ConsumerWidget {
  const _SessionInfoCard({required this.stats, required this.onRefresh});

  final SessionStats? stats;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final piState = ref.watch(piSessionProvider);
    final colors = Theme.of(context).colorScheme;
    final connected =
        piState.status == PiConnStatus.connected &&
        piState.selectedSource?.connected == true;
    final canExport =
        piState.canControl &&
        (piState.selectedSource?.supports('export_html') ?? false);
    final stats = this.stats;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('工作目录'),
            subtitle: Text(piState.cwd ?? '-'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('会话'),
            subtitle: Text(piState.sessionName ?? piState.sessionId ?? '-'),
          ),
          if (stats != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tokens: 输入 ${_fmtTokens(stats.inputTokens)} · 输出 ${_fmtTokens(stats.outputTokens)} · 合计 ${_fmtTokens(stats.totalTokens)}',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '成本: \$${stats.costTotal?.toStringAsFixed(4) ?? '-'}',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (stats.contextPercent != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (stats.contextPercent! / 100).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '上下文 ${stats.contextPercent}% (${_fmtTokens(stats.contextTokens)} / ${_fmtTokens(stats.contextWindow)})',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: connected ? onRefresh : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新统计'),
              ),
              TextButton.icon(
                onPressed: canExport
                    ? () async {
                        final path = await ref
                            .read(piSessionProvider.notifier)
                            .exportHtml();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                path != null ? '已导出: $path' : '导出失败',
                              ),
                            ),
                          );
                        }
                      }
                    : null,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('导出 HTML'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
