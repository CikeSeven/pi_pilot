import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/background_permission.dart';
import '../../core/diagnostics.dart';
import '../../core/notification_service.dart';
import '../theme/shapes.dart';
import '../theme/typography.dart';
import 'background_permission_guide.dart';

/// 诊断页(stable-plan.md §16.3)。
///
/// 定位:用户遇到「通知没来/延迟」时的自助排查入口,也是向 issue 粘贴
/// 脱敏 JSON 的来源 —— 用户不该需要会抓 logcat 才能提供有效信息。
///
/// 三个数据源此前都已存在但没有 UI 消费(ConnectionMetrics /
/// WatcherDiagnostics / BackgroundPermissionState),这个页面把它们接上。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  OwnerStatusReport? _owner;
  Map<String, Object?> _metrics = const {};
  String _watcherLog = '';
  BackgroundPermissionStatus? _permission;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final service = DiagnosticsService.instance;
    final results = await Future.wait([
      service.readOwnerStatus(),
      service.readConnectionMetrics(),
      service.readWatcherDiagnostics(),
      NotificationService.instance.readBackgroundPermissionState(),
    ]);
    if (!mounted) return;
    setState(() {
      _owner = results[0] as OwnerStatusReport?;
      _metrics = results[1] as Map<String, Object?>;
      _watcherLog = results[2] as String;
      _permission = results[3] as BackgroundPermissionStatus;
      _loading = false;
    });
  }

  Future<void> _toggleNativeOwner(bool enabled) async {
    final ok = await DiagnosticsService.instance.setNativeLanOwner(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '已切换,下次进入后台时生效' : '切换失败(原生侧拒绝)',
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _export() async {
    final permission = _permission;
    final json = buildDiagnosticsExport(
      owner: _owner,
      metrics: _metrics,
      watcherLog: _watcherLog,
      permission: permission == null
          ? const {'unavailable': true}
          : {
              'verdict': permission.verdict.name,
              'vendor': permission.vendor.name,
              'manufacturer': permission.manufacturer,
              'sdkInt': permission.sdkInt,
              'ignoringBatteryOptimizations':
                  permission.ignoringBatteryOptimizations,
              'backgroundRestricted': permission.backgroundRestricted,
              'standbyBucket': permission.standbyBucket,
            },
    );
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('脱敏诊断 JSON 已复制到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出脱敏 JSON',
            onPressed: _loading ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _buildPermissionCard(),
                const SizedBox(height: 12),
                _buildOwnerCard(),
                const SizedBox(height: 12),
                _buildMetricsCard(),
                const SizedBox(height: 12),
                _buildLogCard(),
              ],
            ),
    );
  }

  Widget _buildPermissionCard() {
    final permission = _permission;
    if (permission == null ||
        permission.verdict == BackgroundPermissionVerdict.unknown) {
      return const SizedBox.shrink();
    }
    final ok = permission.verdict == BackgroundPermissionVerdict.unrestricted;
    final color = ok
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Card(
      child: ListTile(
        leading: Icon(
          ok ? Icons.battery_saver : Icons.battery_alert_outlined,
          color: color,
        ),
        title: const Text('后台运行'),
        subtitle: Text(permission.summary),
        trailing: ok
            ? Icon(Icons.check_circle_outline, color: color)
            : TextButton(
                onPressed: () =>
                    showBackgroundPermissionGuide(context, permission),
                child: const Text('如何开启'),
              ),
      ),
    );
  }

  Widget _buildOwnerCard() {
    final owner = _owner;
    if (owner == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.error_outline),
          title: Text('后台连接'),
          subtitle: Text('读取失败(原生侧无响应)'),
        ),
      );
    }
    final active = owner.active;
    final state =
        active['state'] as String? ?? (owner.ready ? 'READY' : 'DISCONNECTED');
    final host = active['host'] as String? ?? '';
    final port = (active['port'] as num?)?.toInt() ?? 0;
    final bridgeId = active['bridgeInstallationId'] as String? ?? '';
    final cursor = (active['cursorThrough'] as num?)?.toInt() ?? -1;
    final reconnectAttempt = (active['reconnectAttempt'] as num?)?.toInt() ?? 0;
    final reconnectPending = active['reconnectPending'] as bool? ?? false;

    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.hub_outlined),
            title: const Text('原生 LAN owner'),
            subtitle: Text(
              owner.nativeLanOwnerFlag
                  ? '当前:${owner.activeOwnerLabel} · 关闭可回退兼容 watcher'
                  : '当前:${owner.activeOwnerLabel} · 默认关闭',
            ),
            value: owner.nativeLanOwnerFlag,
            onChanged: _toggleNativeOwner,
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              owner.ready ? Icons.link : Icons.link_off,
              color: owner.ready
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            title: Text(owner.ready ? '后台通知已就绪' : '未就绪'),
            subtitle: Text(
              [
                '状态 $state',
                if (host.isNotEmpty) '端点 $host:$port',
                if (bridgeId.isNotEmpty) 'bridge $bridgeId…',
                if (cursor >= 0) 'cursor $cursor',
                if (reconnectPending) '重连中(第 $reconnectAttempt 次)',
              ].join(' · '),
            ),
          ),
          if (owner.backgroundMode == 'QUOTA_EXHAUSTED')
            ListTile(
              leading: Icon(
                Icons.hourglass_disabled,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('前台服务配额已用完'),
              subtitle: Text(
                owner.quotaExhaustedAt > 0
                    ? '发生于 ${_formatMillis(owner.quotaExhaustedAt)},打开应用可补齐错过的提醒'
                    : '打开应用可补齐错过的提醒',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMetricsCard() {
    // 扁平 Map 里 count:<reason> 是计数,last:<reason> 是最近一次时间戳。
    final counters = <String, int>{};
    final lastAt = <String, int>{};
    for (final entry in _metrics.entries) {
      if (entry.key.startsWith('count:')) {
        counters[entry.key.substring(6)] = (entry.value as num?)?.toInt() ?? 0;
      } else if (entry.key.startsWith('last:')) {
        lastAt[entry.key.substring(5)] = (entry.value as num?)?.toInt() ?? 0;
      }
    }
    final reasons = counters.keys.toList()..sort();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.query_stats),
            title: const Text('连接指标'),
            subtitle: Text(
              reasons.isEmpty ? '暂无记录' : '${reasons.length} 类事件',
            ),
            trailing: reasons.isEmpty
                ? null
                : TextButton(
                    onPressed: () async {
                      await DiagnosticsService.instance
                          .clearConnectionMetrics();
                      await _refresh();
                    },
                    child: const Text('清空'),
                  ),
          ),
          if (reasons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final reason in reasons)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '$reason × ${counters[reason]}'
                        '${lastAt.containsKey(reason) ? ' · 最近 ${_formatMillis(lastAt[reason]!)}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLogCard() {
    final lines = _watcherLog
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    // 只显示尾部:全文可能上千行,长列表会卡。
    final tail = lines.length > 80 ? lines.sublist(lines.length - 80) : lines;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('连接诊断日志'),
            subtitle: Text('共 ${lines.length} 行,显示末尾 ${tail.length} 行'),
            trailing: lines.isEmpty
                ? null
                : TextButton(
                    onPressed: () async {
                      await DiagnosticsService.instance
                          .clearWatcherDiagnostics();
                      await _refresh();
                    },
                    child: const Text('清空'),
                  ),
          ),
          if (tail.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(12),
              decoration: ShapeDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
                shape: PiShape.card,
              ),
              child: SelectableText(
                tail.join('\n'),
                style: AppType.monoSmall(),
              ),
            ),
        ],
      ),
    );
  }

  static String _formatMillis(int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final sameDay = time.year == now.year &&
        time.month == now.month &&
        time.day == now.day;
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    return sameDay ? clock : '${time.month}-${two(time.day)} $clock';
  }
}
