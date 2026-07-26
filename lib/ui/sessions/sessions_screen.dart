import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../main_shell.dart';

/// 会话管理页:按工作目录分组浏览 pi 会话,支持切换/新建/跨目录切换。
class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  List<DirEntry>? _dirs;
  final Map<String, List<SessionEntry>> _sessions = {};
  final Set<String> _loadingDirs = {};
  bool _loading = false;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll());
  }

  Future<void> _refreshAll() async {
    await ref.read(piSessionProvider.notifier).refreshSources();
    await _refresh();
  }

  Future<void> _refresh() async {
    final piState = ref.read(piSessionProvider);
    final connected = piState.status == PiConnStatus.connected;
    if (!connected || !piState.canBrowseSessions) {
      setState(() {
        _dirs = null;
        _sessions.clear();
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dirs = await ref.read(piSessionProvider.notifier).listDirs();
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _sessions.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadSessions(String cwd) async {
    if (_sessions.containsKey(cwd) || _loadingDirs.contains(cwd)) return;
    _loadingDirs.add(cwd);
    final list = await ref.read(piSessionProvider.notifier).listSessions(cwd);
    if (!mounted) return;
    setState(() {
      _sessions[cwd] = list;
      _loadingDirs.remove(cwd);
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _runSwitch(
    Future<bool> Function() action,
    String doneText,
  ) async {
    setState(() => _switching = true);
    final ok = await action();
    if (!mounted) return;
    setState(() => _switching = false);
    _snack(ok ? doneText : '操作失败或被取消');
    if (ok) ref.read(selectedTabProvider.notifier).select(0);
  }

  bool _guardStreaming() {
    final piState = ref.read(piSessionProvider);
    if (!piState.canControl) {
      _snack('请先取得 headless source 的控制权');
      return true;
    }
    if (piState.isStreaming) {
      _snack('任务运行中,请先中断再切换');
      return true;
    }
    return false;
  }

  void _openSession(DirEntry dir, SessionEntry session) {
    if (_guardStreaming()) return;
    final currentCwd = ref.read(piSessionProvider).cwd;
    if (dir.cwd == currentCwd) {
      _runSwitch(
        () => ref.read(piSessionProvider.notifier).switchSession(session.path),
        '已切换会话',
      );
      return;
    }
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('切换工作目录?'),
        content: Text('pi 进程将重启并切换到:\n${dir.cwd}\n(约几秒钟,当前任务会中断)'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _runSwitch(
                () => ref
                    .read(piSessionProvider.notifier)
                    .switchDir(dir.cwd, sessionPath: session.path),
                '已切换目录并打开会话',
              );
            },
            child: const Text('切换'),
          ),
        ],
      ),
    );
  }

  void _newSession() {
    if (_guardStreaming()) return;
    _runSwitch(
      () => ref.read(piSessionProvider.notifier).newSession(),
      '已创建新会话',
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(piSessionProvider.select((s) => s.status), (_, next) {
      if (next == PiConnStatus.connected) _refreshAll();
    });
    ref.listen(piSessionProvider.select((s) => s.selectedSourceId), (_, _) {
      _refresh();
    });
    ref.listen(piSessionProvider.select((s) => s.sessionId), (_, _) {
      _refresh();
    });

    final piState = ref.watch(piSessionProvider);
    final connected = piState.status == PiConnStatus.connected;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: connected && !_loading ? _refreshAll : null,
          ),
          IconButton(
            tooltip: '新建会话(当前目录)',
            icon: const Icon(Icons.add),
            onPressed:
                piState.canBrowseSessions && piState.canControl && !_switching
                ? _newSession
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _SourcePicker(
            sources: piState.sources,
            selectedSourceId: piState.selectedSourceId,
            busy: _switching,
            onSelected: (sourceId) async {
              setState(() => _switching = true);
              final ok = await ref
                  .read(piSessionProvider.notifier)
                  .selectSource(sourceId);
              if (!mounted) return;
              setState(() => _switching = false);
              if (!ok) _snack('source 选择失败');
              await _refresh();
            },
            onRefresh: _refreshAll,
          ),
          if (_switching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody(connected, piState, colors)),
        ],
      ),
    );
  }

  Widget _buildBody(bool connected, PiState piState, ColorScheme colors) {
    if (!connected) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: colors.outline),
            const SizedBox(height: 16),
            const Text('连接后可见会话列表'),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => ref.read(selectedTabProvider.notifier).select(2),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('前往设置'),
            ),
          ],
        ),
      );
    }
    final source = piState.selectedSource;
    if (source == null) {
      return const Center(child: Text('请选择一个在线 pi source'));
    }
    if (source.isDesktop) {
      return _DesktopSourceView(source: source, piState: piState);
    }
    if (_loading && _dirs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('加载失败: $_error'));
    }
    final dirs = _dirs;
    if (dirs == null || dirs.isEmpty) {
      return const Center(child: Text('暂无会话'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: dirs.length,
        itemBuilder: (context, index) => _dirTile(dirs[index], piState, colors),
      ),
    );
  }

  Widget _dirTile(DirEntry dir, PiState piState, ColorScheme colors) {
    final isCurrentDir = dir.cwd == piState.cwd;
    final sessions = _sessions[dir.cwd];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: isCurrentDir,
        onExpansionChanged: (expanded) {
          if (expanded) _loadSessions(dir.cwd);
        },
        leading: Icon(
          isCurrentDir ? Icons.folder_open : Icons.folder_outlined,
          color: isCurrentDir ? colors.primary : null,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                dir.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isCurrentDir ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (isCurrentDir)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '当前',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${dir.cwd}\n${dir.sessionCount} 个会话 · ${_relativeTime(dir.lastActive)}',
          maxLines: 2,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        children: [
          if (sessions == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (sessions.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('此目录暂无会话'))
          else
            for (final session in sessions)
              _sessionTile(dir, session, piState, colors),
        ],
      ),
    );
  }

  Widget _sessionTile(
    DirEntry dir,
    SessionEntry session,
    PiState piState,
    ColorScheme colors,
  ) {
    final isCurrent = session.id == piState.sessionId;
    return ListTile(
      dense: true,
      enabled: !_switching && piState.canControl,
      leading: Icon(
        isCurrent ? Icons.check_circle : Icons.chat_bubble_outline,
        size: 20,
        color: isCurrent ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(
        session.name ?? '未命名会话',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        '${_relativeTime(session.timestamp)} · ${(session.sizeBytes / 1024).toStringAsFixed(1)} KB',
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
      ),
      onTap: isCurrent ? null : () => _openSession(dir, session),
    );
  }
}

class _SourcePicker extends StatelessWidget {
  const _SourcePicker({
    required this.sources,
    required this.selectedSourceId,
    required this.busy,
    required this.onSelected,
    required this.onRefresh,
  });

  final List<SourceInfo> sources;
  final String? selectedSourceId;
  final bool busy;
  final ValueChanged<String> onSelected;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = sources
        .where((source) => source.id == selectedSourceId)
        .firstOrNull;
    return Material(
      color: colors.surfaceContainerLow,
      child: ListTile(
        leading: Icon(
          selected?.isDesktop == true
              ? Icons.desktop_windows_outlined
              : Icons.dns_outlined,
          color: selected?.connected == true ? colors.primary : colors.outline,
        ),
        title: Text(
          selected?.label ?? '选择 pi source',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          selected == null
              ? '${sources.where((source) => source.connected).length} 个在线 source'
              : '${selected.isDesktop ? '桌面 TUI' : 'Headless RPC'} · ${selected.connected ? '在线' : '离线'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '刷新 source',
              onPressed: busy ? null : () => onRefresh(),
              icon: const Icon(Icons.refresh),
            ),
            PopupMenuButton<String>(
              tooltip: '选择 source',
              enabled:
                  !busy &&
                  sources.any(
                    (source) => source.connected || source.isHeadless,
                  ),
              onSelected: onSelected,
              itemBuilder: (context) => [
                for (final source in sources)
                  PopupMenuItem(
                    value: source.id,
                    enabled: source.connected || source.isHeadless,
                    child: Row(
                      children: [
                        Icon(
                          source.isDesktop
                              ? Icons.desktop_windows_outlined
                              : Icons.dns_outlined,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            source.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (source.id == selectedSourceId)
                          const Icon(Icons.check, size: 18),
                      ],
                    ),
                  ),
              ],
              icon: const Icon(Icons.expand_more),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSourceView extends ConsumerWidget {
  const _DesktopSourceView({required this.source, required this.piState});

  final SourceInfo source;
  final PiState piState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final unavailable = source.ownerPresent && !piState.ownsSource;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.desktop_windows_outlined,
              size: 56,
              color: source.connected ? colors.primary : colors.outline,
            ),
            const SizedBox(height: 16),
            Text(source.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              piState.sessionName ?? piState.sessionId ?? '当前桌面会话',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (piState.cwd != null) ...[
              const SizedBox(height: 4),
              Text(
                piState.cwd!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 20),
            if (piState.ownsSource)
              OutlinedButton.icon(
                onPressed: () =>
                    ref.read(piSessionProvider.notifier).releaseControl(),
                icon: const Icon(Icons.lock_outline),
                label: const Text('释放控制权'),
              )
            else
              FilledButton.icon(
                onPressed: unavailable || !source.connected
                    ? null
                    : () async {
                        final ok = await ref
                            .read(piSessionProvider.notifier)
                            .acquireControl();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(ok ? '已取得控制权' : '接管失败')),
                        );
                      },
                icon: const Icon(Icons.touch_app_outlined),
                label: Text(unavailable ? '其他客户端正在控制' : '接管控制'),
              ),
          ],
        ),
      ),
    );
  }
}

String _relativeTime(DateTime? t) {
  if (t == null) return '未知时间';
  final diff = DateTime.now().difference(t);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final mm = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '${t.year}-$mm-$dd';
}
