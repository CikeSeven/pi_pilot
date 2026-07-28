import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../main_shell.dart';
import 'widgets/chat_item_view.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottomIfNear() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 240) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    ref.read(piSessionProvider.notifier).sendPrompt(text);
    _input.clear();
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接?'),
        content: const Text('会话仍会保留在电脑上,下次连接可增量恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(piSessionProvider.notifier).disconnect();
    }
  }

  String _subtitle(PiState state) {
    if (state.status != PiConnStatus.connected) {
      return switch (state.status) {
        PiConnStatus.connecting => '连接中…',
        PiConnStatus.failed => '连接失败',
        _ => '未连接',
      };
    }
    final source = state.selectedSource;
    if (source == null) return '请选择 pi source';
    final dir = state.cwd?.split('/').where((p) => p.isNotEmpty).lastOrNull;
    return [
      source.label,
      ?dir,
      ?state.sessionName,
      ?state.modelName,
      ?state.thinkingLevel,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      piSessionProvider.select((s) => s.revision),
      (_, _) => _scrollToBottomIfNear(),
    );

    final state = ref.watch(piSessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _StatusDot(status: state.status),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PiPilot',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _subtitle(state),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (state.isStreaming && state.canControl)
            IconButton(
              tooltip: '中断',
              icon: Icon(
                Icons.stop_circle_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => ref.read(piSessionProvider.notifier).abort(),
            ),
          if (state.hasSession)
            IconButton(
              tooltip: '断开连接',
              icon: const Icon(Icons.link_off),
              onPressed: _confirmDisconnect,
            ),
        ],
      ),
      body: !state.hasSession
          ? const _NotConnectedView()
          : Column(
              children: [
                _ControlBanner(state: state),
                if (state.followUpQueue.isNotEmpty ||
                    state.steeringQueue.isNotEmpty)
                  _QueueBanner(
                    steering: state.steeringQueue,
                    followUp: state.followUpQueue,
                  ),
                if (state.isCompacting)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: state.items.isEmpty
                      ? const _EmptyHint()
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          itemCount: state.items.length,
                          itemBuilder: (context, index) =>
                              ChatItemView(item: state.items[index]),
                        ),
                ),
                _Composer(
                  controller: _input,
                  enabled: state.canControl,
                  streaming: state.isStreaming,
                  onSend: _send,
                ),
              ],
            ),
    );
  }
}

class _NotConnectedView extends ConsumerWidget {
  const _NotConnectedView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(piSessionProvider.select((s) => s.status));
    final error = ref.watch(piSessionProvider.select((s) => s.error));
    final hasConn = ref.watch(settingsProvider.select((s) => s.hasConnection));
    final colors = Theme.of(context).colorScheme;

    final (icon, message) = switch (status) {
      PiConnStatus.connecting => (Icons.sync, '正在连接…'),
      PiConnStatus.failed => (Icons.cloud_off_outlined, '连接失败'),
      _ => (Icons.cloud_off_outlined, '尚未连接'),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: colors.outline),
            const SizedBox(height: 16),
            Text(message, style: Theme.of(context).textTheme.titleMedium),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (status != PiConnStatus.connecting && hasConn)
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(piSessionProvider.notifier).connect(),
                    icon: const Icon(Icons.link),
                    label: const Text('连接'),
                  ),
                OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(selectedTabProvider.notifier).select(2),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('前往设置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final PiConnStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (status) {
      PiConnStatus.connected => Colors.green,
      PiConnStatus.connecting => colors.tertiary,
      PiConnStatus.failed => colors.error,
      PiConnStatus.disconnected => colors.outlineVariant,
    };
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _ControlBanner extends ConsumerWidget {
  const _ControlBanner({required this.state});

  final PiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = state.selectedSource;
    final colors = Theme.of(context).colorScheme;
    final (icon, text, actionLabel) = source == null
        ? (Icons.desktop_windows_outlined, '未选择 pi source', '选择')
        : !source.connected && !source.isHeadless
        ? (Icons.desktop_access_disabled_outlined, '${source.label} 已离线', '刷新')
        : state.ownsSource
        ? (Icons.lock_open_outlined, '正在控制 ${source.label}', '释放')
        : source.ownerPresent
        ? (Icons.visibility_outlined, '观察模式 · 其他客户端正在控制', '查看')
        : (
            Icons.visibility_outlined,
            source.connected ? '观察模式 · ${source.label}' : '${source.label} 已停止',
            source.connected ? '接管' : '启动',
          );

    Future<void> runAction() async {
      if (source == null || (source.ownerPresent && !state.ownsSource)) {
        ref.read(selectedTabProvider.notifier).select(1);
        return;
      }
      if (!source.connected && !source.isHeadless) {
        await ref.read(piSessionProvider.notifier).refreshSources();
        return;
      }
      if (state.ownsSource) {
        await ref.read(piSessionProvider.notifier).releaseControl();
        return;
      }
      final ok = await ref.read(piSessionProvider.notifier).acquireControl();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已取得控制权' : '接管失败,source 可能已被占用')),
      );
    }

    return Container(
      width: double.infinity,
      color: state.ownsSource
          ? colors.primaryContainer
          : colors.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: state.ownsSource
                ? colors.onPrimaryContainer
                : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: state.ownsSource
                    ? colors.onPrimaryContainer
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: runAction,
            icon: Icon(
              state.ownsSource
                  ? Icons.lock_outline
                  : source == null
                  ? Icons.list
                  : Icons.touch_app_outlined,
              size: 17,
            ),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _QueueBanner extends StatelessWidget {
  const _QueueBanner({required this.steering, required this.followUp});

  final List<String> steering;
  final List<String> followUp;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final parts = <String>[
      if (steering.isNotEmpty) 'steer ×${steering.length}',
      if (followUp.isNotEmpty) 'follow-up ×${followUp.length}',
    ];
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 13, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '队列: ${parts.join(' · ')} — ${[...steering, ...followUp].first}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          '给 pi 下达你的第一个指令吧\n例如:「看看当前目录结构」',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.streaming,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool streaming;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: streaming
                      ? '运行中,发送将加入 follow-up 队列…'
                      : '指挥 pi 做点什么…',
                  hintStyle: TextStyle(color: colors.onSurfaceVariant),
                  filled: true,
                  fillColor: colors.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
