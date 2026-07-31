import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../theme/paper.dart';
import '../theme/shapes.dart';
import '../theme/typography.dart';
import '../theme/squircle.dart';

/// 设备页:**深炭全屏 + 复古插画 + 陶土橙当前卡**。
///
/// Editorial Retro 改版。参考图里设备列表是整个 app 唯一的深色全屏页面——
/// 「一张深色侧边抽屉、一台当前设备卡片、背景有淡淡的复古场景插图,
/// 很有工作台的感觉」。
///
/// 分两段:**pi 窗口**(电脑上开着的)+ **历史会话**(只在磁盘上的)。
///
/// 原设计刻意*不*枚举 `~/.pi/agent/sessions/`,理由是「手机只负责连到已经开着
/// 的窗口」。这条决策在这里被推翻,因为它让大会话对手机**永久不可达**:
/// 本机最大的会话是 50.40MB / 9554 条,只在磁盘上,电脑端没开着它 ——
/// 于是无论 bridge 侧把分页做得多快,用户在手机上都找不到入口打开它。
/// bridge 早就把磁盘会话一起发过来了(`hub_list_sessions` 实测 63 个,
/// 带 sizeBytes/timestamp/path),`openSession()` 也早就能唤醒它们 ——
/// 缺的一直只是这段列表 UI。
///
/// 「电脑上多开一个 pi,这里就多一行」的原意在**第一段**里完整保留。
///
/// 同一份 UI 有两个外壳:
/// - [DevicesPage]  底部导航的「设备」tab,整页;
/// - [DevicesDrawer] 会话页左滑出来的抽屉。
/// 两者共用 [_DevicesBody],避免两处各写一遍列表。
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 背景明暗**跟随主题**。旧版这里写死 `dark: true`,于是浅色模式下
    // 别的页面是奶油纸、这一页却是深炭黑,切过去像换了个 app ——
    // 那就是「撕裂感」的真正来源。
    // 两用页面:既作底栏「设备」tab,也作 push 路由。
    // 自带 BackdropPaper 保证两种场景背景都正确(详见 SettingsScreen 注释)。
    return const Scaffold(
      body: BackdropPaper(child: _DevicesBody(inDrawer: false)),
    );
  }
}

/// 抽屉外壳。深炭底由 `drawerTheme` 给。
class DevicesDrawer extends StatelessWidget {
  const DevicesDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    // 抽屉从左侧滑出,贴着屏幕左边缘,所以左侧(上下)都是直角。
    // 只有**右侧上方**圆角 —— 它是抽屉右上那个「开口的纸角」。
    // 右下方必须直角:抽屉底部要贴住屏幕底,圆角会让底下透出主页造成
    // 「悬空」的错觉(就是之前看着怪的那处)。
    return const Drawer(
      child: ClipRRect(
        borderRadius: BorderRadius.only(topRight: Radius.circular(PiShape.lg)),
        child: BackdropPaper(child: _DevicesBody(inDrawer: true)),
      ),
    );
  }
}

class _DevicesBody extends ConsumerStatefulWidget {
  const _DevicesBody({required this.inDrawer});

  /// 抽屉里点一台设备要先关抽屉;整页里不需要。
  final bool inDrawer;

  @override
  ConsumerState<_DevicesBody> createState() => _DevicesBodyState();
}

class _DevicesBodyState extends ConsumerState<_DevicesBody> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    if (ref.read(piSessionProvider).status != PiConnStatus.connected) return;
    final notifier = ref.read(piSessionProvider.notifier);
    // 两个都要拉:refreshSources 只给「开着的窗口」,磁盘上的历史会话
    // 只有 hub_list_sessions 才带回来(它连 sizeBytes/path 一起给)。
    // 少拉后者,下面的「历史会话」段就永远是空的。
    await notifier.refreshSources();
    if (!mounted) return;
    await notifier.refreshHubSessions();
  }

  /// 唤醒一个只在磁盘上的会话。bridge 会按需 spawn 一个无头 pi 并订阅它,
  /// **从不 kill 任何进程**,所以电脑端正在生成时点这里也不会互相打断。
  Future<void> _wake(HubSession session) async {
    final messenger = ScaffoldMessenger.of(context);
    if (widget.inDrawer) Navigator.of(context).pop();
    String? error;
    var ok = false;
    try {
      ok = await ref.read(piSessionProvider.notifier).openSession(
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
    final reason = error ?? ref.read(piSessionProvider).error ?? '唤醒这个会话失败';
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(reason)));
  }

  Future<void> _connect(SourceInfo source) async {
    // pop / snackbar 都要用外层 context,先抓好
    final messenger = ScaffoldMessenger.of(context);
    // 先关抽屉再连:selectSource 要跑整轮同步(数秒),如果连完才 pop,
    // 期间用户已从抽屉进了设置页的话,这一下 pop 会把设置页误关掉。
    if (widget.inDrawer) Navigator.of(context).pop();
    String? error;
    var ok = false;
    try {
      ok = await ref.read(piSessionProvider.notifier).selectSource(source.id);
    } catch (failure) {
      error = failure.toString();
    }
    if (ok) return;
    final reason = error ?? ref.read(piSessionProvider).error ?? '连接这个窗口失败';
    messenger.showSnackBar(SnackBar(content: Text(reason)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(piSessionProvider);
    final connected = state.status == PiConnStatus.connected;

    // 第一段:电脑上开着的窗口。headless / 已断开的都不列。
    final windows = [
      for (final source in state.sources)
        if (source.isDesktop && source.connected) source,
    ];

    // 第二段:不在电脑窗口里的会话 —— 磁盘上休眠的(dormant)和已经被唤醒、
    // 活在 bridge 进程池里的(headless)都算。
    //
    // headless 必须一起收:否则点开一个历史会话、它变成 headless 之后,
    // 窗口段(只收 isDesktop)和历史段(只收 dormant)都不要它,这一行就
    // **凭空消失**,用户既看不出它在跑,也没法再回到它。
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
      // timestamp 是 ISO8601,字符串降序即时间降序。缺失的排最后。
      final left = a.timestamp ?? '';
      final right = b.timestamp ?? '';
      if (left.isEmpty && right.isEmpty) return 0;
      if (left.isEmpty) return 1;
      if (right.isEmpty) return -1;
      return right.compareTo(left);
    });

    return Stack(
      children: [
        // 这里曾放一张「工作台」环境插画做氛围。撤掉了:
        // 素材自带象牙纸底,在深炭页面上无论怎么混合都会留下一块灰方块
        // (screen 提亮成灰块 / multiply 把线条一起压黑)。
        // 深色页面的识别度已经由陶土橙当前卡 + 衬线标题承担,不缺这一层。
        SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                connected: connected,
                onRefresh: connected ? _refresh : null,
              ),
              Expanded(child: _body(state, connected, windows, history)),
              // 抽屉页脚原本有个「设置」入口。撤掉了:底栏已经有「设置」tab,
              // 同一个目的地给两个入口只会让人犹豫点哪个。
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(
    PiState state,
    bool connected,
    List<SourceInfo> windows,
    List<HubSession> history,
  ) {
    if (!connected) {
      return const _Placeholder(
        title: '尚未连接',
        body: '在设置里填写 bridge 地址,\n就能看到电脑上开着的 pi 窗口。',
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
          _DeviceCard(
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

/// 页头:衬线大标题 + 说明 + 刷新。
class _Header extends StatelessWidget {
  const _Header({required this.connected, this.onRefresh});

  final bool connected;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    // 颜色一律从 scheme 取 —— 这一页现在跟随主题,写死深色前景在浅色下就瞎了。
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'pi 窗口',
                      style: AppType.displayTitle(
                        size: 27,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 素材里的星芒 PNG 自带象牙底,深色页面上是个小白块 ——
                    // 这里用同形状的 Material 图标代替。
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 15,
                        color: colors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                icon: Icon(Icons.refresh, color: colors.onSurfaceVariant),
                onPressed: onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            connected ? '电脑上每开一个 pi,这里就多一个' : '未连接 bridge',
            style: AppType.serifItalic(
              size: 14,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Eyebrow(
            text: connected ? '在线设备' : '离线',
            color: colors.primary,
            withRule: true,
          ),
        ],
      ),
    );
  }
}

/// 设备卡:当前连接的那台用**陶土橙实心**,其余用深色抬升面 + 描边。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
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

    // 当前设备:主强调色实心卡,是这一页的视觉主角(参考图如此)。
    // 其余用一级卡片面 —— 浅色下是象牙白、深色下是深咖灰,都由主题给。
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
              // 设备图标:方正印章
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
                // 「当前」标:编辑式小标签,不是红角标
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
///
/// 视觉上刻意比 [_DeviceCard] 轻一档(描边卡 + 虚线感图标),因为它还不是
/// 一个活着的窗口 —— 避免和「当前」那张陶土橙实心卡抢视觉重心。
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
    // headless = 已经在 bridge 上跑着;dormant = 只在磁盘上,点了才唤醒。
    final running = session.liveness == SessionLiveness.headless;

    // 副标题把「多大 · 什么时候」摆出来:大会话唤醒要花几秒,
    // 让人点之前就知道自己在打开一个多大的东西。
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
                  child: Text('当前', style: AppType.eyebrow(color: colors.primary)),
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
  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return '今天 ${two(local.hour)}:${two(local.minute)}';
  }
  if (local.year == now.year) return '${local.month}月${local.day}日';
  return '${local.year}/${two(local.month)}/${two(local.day)}';
}

/// 空态:插画 + 衬线标题 + 说明。深色底版本。
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.body});

  final String title;
  final String body;

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
              // 矢量装饰替代插画 PNG:PNG 自带象牙纸底,深色页面上是一块灰方块。
              // CustomPaint 天然透明,还能跟着主题色走。
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
            ],
          ),
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
