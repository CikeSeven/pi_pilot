import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../settings/settings_screen.dart';
import '../theme/semantic_colors.dart';

/// 会话抽屉:**列出电脑上当前开着的 pi 窗口**,点一下连过去。
///
/// 这里刻意*不*枚举 `~/.pi/agent/sessions/` 里的历史会话文件。之前那版把磁盘上
/// 所有会话都列了出来,点进去还会为它 spawn 一个新的 pi 进程 —— 那既不是用户
/// 要的,也会在电脑上凭空多出进程,而且对桌面源发 `switch_session` 会被 bridge
/// 直接拒绝(那会把人正在用的会话从 TUI 里抽走),表现就是「一直操作失败」。
///
/// 手机的职责只有一个:连到**已经开着的窗口**上去。电脑上多开一个 pi,
/// 这里就多一行;关掉一个,这里就少一行。
class SessionDrawer extends ConsumerStatefulWidget {
  const SessionDrawer({super.key});

  @override
  ConsumerState<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends ConsumerState<SessionDrawer> {
  @override
  void initState() {
    super.initState();
    // 抽屉每次打开都重建,这里顺手拉一次最新的窗口列表
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    if (ref.read(piSessionProvider).status != PiConnStatus.connected) return;
    await ref.read(piSessionProvider.notifier).refreshSources();
  }

  Future<void> _connect(SourceInfo source) async {
    // pop / snackbar 都要用抽屉之外的 context,先抓好
    final messenger = ScaffoldMessenger.of(context);
    // 先关抽屉再连:selectSource 要跑整轮同步(数秒),如果连完才 pop,
    // 期间用户已从抽屉进了设置页的话,这一下 pop 会把设置页误关掉。
    // 失败通过 app 级 messenger 的 snackbar 告知,不依赖抽屉还在。
    Navigator.of(context).pop();
    String? error;
    var ok = false;
    try {
      ok = await ref.read(piSessionProvider.notifier).selectSource(source.id);
    } catch (failure) {
      error = failure.toString();
    }
    if (ok) return;
    final reason =
        error ?? ref.read(piSessionProvider).error ?? '连接这个窗口失败';
    messenger.showSnackBar(SnackBar(content: Text(reason)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(piSessionProvider);
    final theme = Theme.of(context);
    final connected = state.status == PiConnStatus.connected;

    // 只要电脑上开着的窗口。headless / 已断开的都不列。
    final windows = [
      for (final source in state.sources)
        if (source.isDesktop && source.connected) source,
    ];

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('pi 窗口', style: theme.textTheme.headlineSmall),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh),
                    onPressed: connected ? _refresh : null,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 20, 12),
              child: Text(
                connected ? '电脑上每开一个 pi,这里就多一个' : '未连接 bridge',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: _body(theme, state, connected, windows)),            Divider(
              height: 1,
              indent: 28,
              endIndent: 28,
              color: theme.colorScheme.outlineVariant,
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    ThemeData theme,
    PiState state,
    bool connected,
    List<SourceInfo> windows,
  ) {
    if (!connected) {
      return _placeholder(
        theme,
        Icons.cloud_off_outlined,
        '尚未连接',
        '在设置里填写 bridge 地址',
      );
    }
    if (windows.isEmpty) {
      return _placeholder(
        theme,
        Icons.desktop_access_disabled_outlined,
        '电脑上没有打开的 pi',
        '在电脑上开一个 pi 窗口,它会自动出现在这里',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: windows.length,
      itemBuilder: (_, index) => _windowTile(theme, state, windows[index]),
    );
  }

  Widget _windowTile(ThemeData theme, PiState state, SourceInfo source) {
    final piColors = PiColors.of(context);
    final isCurrent = source.id == state.selectedSourceId;
    // 身份色由 sourceId 决定:同一个窗口在任何主题下都是同一个颜色
    final slot = PiColors.identityIndex(source.id);
    final streaming = state.sessions
        .where((item) => item.sourceId == source.id)
        .any((item) => item.streaming);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        shape: const StadiumBorder(),
        selected: isCurrent,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        contentPadding: const EdgeInsets.only(left: 12, right: 16),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: piColors.identity[slot],
          foregroundColor: piColors.onIdentity[slot],
          child: const Icon(Icons.desktop_windows_outlined, size: 20),
        ),
        title: Text(
          windowTitleFor(cwd: source.cwd, sessionName: source.sessionName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge,
        ),
        subtitle: Text(
          streaming ? '正在生成…' : (source.cwd ?? source.label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        trailing: streaming
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: theme.colorScheme.primary,
                ),
              )
            : (isCurrent ? const Badge(label: Text('当前')) : null),
        onTap: isCurrent ? null : () => _connect(source),
      ),
    );
  }

  Widget _placeholder(
    ThemeData theme,
    IconData icon,
    String title,
    String body,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              child: Icon(icon, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
