import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_models.dart';
import '../../state/pi_session.dart';
import '../theme/paper.dart';
import '../theme/shapes.dart';
import '../theme/squircle.dart';
import '../theme/typography.dart';

/// 设备页第二级:**某一台设备的会话列表**。
///
/// 内容就是旧版设备页的正身(pi 窗口 + 历史会话两段),原样从
/// devices_page.dart 搬来——多设备改造后第一级让位给「设备列表」,
/// 会话列表下沉到这里,样式与唤醒/连接逻辑零改动。
///
/// 数据源是这台设备自己的 family 实例 `piSessionFamilyProvider(device.id)`:
/// 多连接保活后,每台设备的状态、会话、唤醒互不影响。
class DeviceSessionsPage extends ConsumerWidget {
  const DeviceSessionsPage({super.key, required this.device});

  final DeviceProfile device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: BackdropPaper(child: _SessionsBody(device: device)),
    );
  }
}

/// 有实时数据时的会话列表(旧 _DevicesBody 的逻辑,按 device 参数化外壳)。
class _SessionsBody extends ConsumerStatefulWidget {
  const _SessionsBody({required this.device});

  final DeviceProfile device;

  @override
  ConsumerState<_SessionsBody> createState() => _SessionsBodyState();
}

class _SessionsBodyState extends ConsumerState<_SessionsBody> {
  /// 本页所有读写都钉在这台设备自己的 family 实例上。
  NotifierProvider<PiSessionNotifier, PiState> get _session =>
      piSessionFamilyProvider(widget.device.id);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    if (ref.read(_session).status != PiConnStatus.connected) return;
    final notifier = ref.read(_session.notifier);
    // 两个都要拉:refreshSources 只给「开着的窗口」,磁盘上的历史会话
    // 只有 hub_list_sessions 才带回来(它连 sizeBytes/path 一起给)。
    await notifier.refreshSources();
    if (!mounted) return;
    await notifier.refreshHubSessions();
  }

  /// 唤醒一个只在磁盘上的会话。bridge 会按需 spawn 一个无头 pi 并订阅它,
  /// **从不 kill 任何进程**,所以电脑端正在生成时点这里也不会互相打断。
  Future<void> _wake(HubSession session) async {
    final messenger = ScaffoldMessenger.of(context);
    String? error;
    var ok = false;
    try {
      ok = await ref
          .read(_session.notifier)
          .openSession(
            sessionId: session.sessionId,
            cwd: session.cwd,
            // sessionPath 是懒唤醒的关键:descriptor 装不下它,
            // 没有它 bridge 只能靠 sessionId 猜文件位置。
            sessionPath: session.path,
          );
    } catch (failure) {
      error = failure.toString();
    }
    if (ok) return;
    final reason = error ?? ref.read(_session).error ?? '唤醒这个会话失败';
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(reason)));
  }

  Future<void> _connect(SourceInfo source) async {
    final messenger = ScaffoldMessenger.of(context);
    String? error;
    var ok = false;
    try {
      ok = await ref.read(_session.notifier).selectSource(source.id);
    } catch (failure) {
      error = failure.toString();
    }
    if (ok) return;
    final reason = error ?? ref.read(_session).error ?? '连接这个窗口失败';
    messenger.showSnackBar(SnackBar(content: Text(reason)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_session);
    final connected = state.status == PiConnStatus.connected;

    // 第一段:电脑上开着的窗口。headless / 已断开的都不列。
    final windows = [
      for (final source in state.sources)
        if (source.isDesktop && source.connected) source,
    ];

    // 第二段:不在电脑窗口里的会话 —— 磁盘上休眠的(dormant)和已经被唤醒、
    // 活在 bridge 进程池里的(headless)都算。headless 必须一起收,否则唤醒后
    // 这一行凭空消失,用户既看不出它在跑,也没法再回到它。
    final shownSessionIds = {
      for (final source in windows) source.sessionId,
    }..removeWhere((id) => id == null);
    final history = [
      for (final session in state.sessions)
        if (session.liveness != SessionLiveness.desktop &&
            session.sessionId.isNotEmpty &&
            !shownSessionIds.contains(session.sessionId))
          session,
    ]..sort((a, b) {
      final left = a.timestamp ?? '';
      final right = b.timestamp ?? '';
      if (left.isEmpty && right.isEmpty) return 0;
      if (left.isEmpty) return 1;
      if (right.isEmpty) return -1;
      return right.compareTo(left);
    });

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PageHeader(
            title: widget.device.name,
            subtitle: connected ? '这台电脑上每开一个 pi,这里就多一个' : '未连接',
            onRefresh: connected ? _refresh : null,
          ),
          Expanded(child: _body(state, connected, windows, history)),
        ],
      ),
    );
  }

  Widget _body(
    PiState state,
    bool connected,
    List<SourceInfo> windows,
    List<HubSession> history,
  ) {
    if (!connected) {
      return _Placeholder(
        title: state.status == PiConnStatus.connecting ? '正在连接…' : '尚未连接',
        body: state.status == PiConnStatus.connecting
            ? '直连优先,失败会自动转 P2P。'
            : '这台设备暂时不在线,\n可以重试,或回设备页检查地址与 token。',
        action: state.status == PiConnStatus.connecting
            ? null
            : FilledButton.icon(
                onPressed: () => ref
                    .read(_session.notifier)
                    .connect(widget.device),
                icon: const Icon(Icons.link),
                label: const Text('重新连接'),
              ),
      );
    }
    if (windows.isEmpty && history.isEmpty) {
      return const _Placeholder(
        title: '电脑上没有打开的 pi',
        body: '在电脑上开一个 pi 窗口,\n它会自动出现在这里。',
      );
    }

    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (windows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
            child: Text(
              '电脑上没有打开的 pi。下面是磁盘上的会话,点一下即时唤醒。',
              style: AppType.serifItalic(
                size: 13.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        for (final source in windows) ...[
          _WindowCard(
            source: source,
            state: state,
            onTap: () => _connect(source),
          ),
          const SizedBox(height: 10),
        ],
        if (history.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(4, windows.isEmpty ? 0 : 14, 4, 12),
            child: Eyebrow(
              text: '会话 · ${history.length}',
              color: colors.onSurfaceVariant,
              withRule: true,
            ),
          ),
          for (final session in history) ...[
            _HistoryCard(
              session: session,
              isCurrent: session.sourceId == state.selectedSourceId,
              onTap: () => _wake(session),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

/// 页头:返回 + 设备名衬线标题 + 说明 + 刷新。
class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.subtitle,
    this.onRefresh,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回',
                icon: Icon(Icons.arrow_back, color: colors.onSurfaceVariant),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.displayTitle(size: 24, color: colors.onSurface),
                ),
              ),
              if (onRefresh != null)
                IconButton(
                  tooltip: '刷新',
                  icon: Icon(Icons.refresh, color: colors.onSurfaceVariant),
                  onPressed: onRefresh,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
            child: Text(
              subtitle,
              style: AppType.serifItalic(
                size: 14,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// pi 窗口卡:当前选中的那个窗口用**陶土橙实心**,其余用抬升面 + 描边。
/// (旧 _DeviceCard 原样——多设备后它管的是「窗口」不是「设备」,故改名。)
class _WindowCard extends StatelessWidget {
  const _WindowCard({
    required this.source,
    required this.state,
    required this.onTap,
  });

  final SourceInfo source;
  final PiState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent = source.id == state.selectedSourceId;
    final streaming = state.sessions
        .where((item) => item.sourceId == source.id)
        .any((item) => item.streaming);

    final colors = theme.colorScheme;
    final bg = isCurrent ? colors.primary : colors.surfaceContainerLow;
    final fg = isCurrent ? colors.onPrimary : colors.onSurface;
    final fgMuted = isCurrent
        ? colors.onPrimary.withValues(alpha: 0.78)
        : colors.onSurfaceVariant;

    return Material(
      color: bg,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(
          color: isCurrent ? Colors.transparent : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isCurrent ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(PiShape.sm),
                  border: Border.all(color: fg.withValues(alpha: 0.22)),
                ),
                child: Icon(
                  Icons.desktop_windows_outlined,
                  size: 20,
                  color: fg,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      windowTitleFor(
                        cwd: source.cwd,
                        sessionName: source.sessionName,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      streaming ? '正在生成…' : (source.cwd ?? source.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoLabel(color: fgMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (streaming)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
                )
              else if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(PiShape.sm),
                  ),
                  child: Text('当前', style: AppType.eyebrow(color: fg)),
                )
              else
                Icon(Icons.chevron_right, size: 20, color: fgMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 历史会话卡:只在磁盘上的会话,点一下即时唤醒。
/// 视觉上刻意比 [_WindowCard] 轻一档,避免和「当前」实心卡抢视觉重心。
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.session,
    required this.isCurrent,
    required this.onTap,
  });

  final HubSession session;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fg = colors.onSurface;
    final fgMuted = colors.onSurfaceVariant;
    final running = session.liveness == SessionLiveness.headless;

    final size = session.sizeBytes;
    final dir = session.cwd;
    final parts = <String>[
      if (running) '运行中',
      if (size != null && size > 0) formatSessionSize(size),
      ?formatSessionTime(session.timestamp),
      if (dir != null && dir.isNotEmpty)
        dir.split('/').where((part) => part.isNotEmpty).lastOrNull ?? dir,
    ];

    return Material(
      color: colors.surfaceContainerLowest,
      shape: SquircleBorder(
        borderRadius: BorderRadius.circular(PiShape.lg),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isCurrent ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: fgMuted.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(PiShape.sm),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Icon(
                  running ? Icons.dns_outlined : Icons.history,
                  size: 18,
                  color: running ? colors.primary : fgMuted,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      windowTitleFor(
                        cwd: session.cwd,
                        sessionName: session.name,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      parts.isEmpty ? '只在磁盘上' : parts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoLabel(color: fgMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(PiShape.sm),
                  ),
                  child: Text(
                    '当前',
                    style: AppType.eyebrow(color: colors.primary),
                  ),
                )
              else
                Icon(Icons.play_arrow_rounded, size: 20, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话文件大小的人类可读形式。大会话是这个产品的常态(本机最大 50.40MB),
/// 所以到 MB 就够,不做 GB 档。
String formatSessionSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

/// 会话时间戳的短形式:今天只给时刻,更早给日期。
/// 解析失败返回 null —— 宁可不显示,也不显示一串 ISO8601 给人看。
String? formatSessionTime(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '今天 ${two(local.hour)}:${two(local.minute)}';
  }
  if (local.year == now.year) return '${local.month}月${local.day}日';
  return '${local.year}/${two(local.month)}/${two(local.day)}';
}

/// 窗口在列表里显示的标题。
///
/// 优先用会话名;pi 只在你显式命名时才写 `session_info.name`,所以大多数时候
/// 是 null,这时退回目录名 —— 那才是用户脑子里区分窗口的方式。
/// 绝不显示 `hostname:pid` 这种 sourceId,它对人没有意义。
String windowTitleFor({required String? cwd, required String? sessionName}) {
  final name = sessionName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final dir = cwd?.split('/').where((part) => part.isNotEmpty).lastOrNull;
  if (dir != null && dir.isNotEmpty) return dir;
  return 'pi 窗口';
}

/// 空态:插画 + 衬线标题 + 说明(+ 可选主行动)。
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.body, this.action});

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EditorialOrnament(size: 132),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppType.displayTitle(size: 22, color: colors.onSurface),
              ),
              const SizedBox(height: 10),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
