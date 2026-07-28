import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pi_session.dart';
import '../../state/settings_provider.dart';
import '../settings/settings_screen.dart';
import 'widgets/chat_item_view.dart';
import 'widgets/composer.dart';
import 'widgets/message_timestamp.dart';
import 'widgets/quick_panel.dart';
import 'widgets/scroll_to_bottom_button.dart';
import 'widgets/ui_request_card.dart';

/// 对话主体。**不再自带 `Scaffold`** —— 那一层上移到了 `AppShell`,
/// 这样才有地方挂抽屉。
class ChatBody extends ConsumerStatefulWidget {
  const ChatBody({super.key});

  @override
  ConsumerState<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<ChatBody> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  String _inputText = '';

  /// 快捷指令没有输入框可清,用它挡住连点(否则会开两个会话、发两条消息)。
  bool _sending = false;

  /// 悬浮输入卡的实测高度,用来给列表留底部空间。
  ///
  /// **不能写死**:输入卡高 = 84 + 系统手势条 inset,再加上展开的快捷面板/
  /// 投递芯片。手势条 48dp 的机器上写死 96 会把最后一条消息压掉 28dp。
  final _composerKey = GlobalKey();
  double _composerHeight = 96;

  void _syncComposerHeight() {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box?.size.height;
    if (height == null || !mounted) return;
    if ((height - _composerHeight).abs() < 0.5) return;
    setState(() => _composerHeight = height);
  }

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

  void _send({PiDelivery? delivery}) {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    unawaited(
      ref.read(piSessionProvider.notifier).sendPrompt(text, delivery: delivery),
    );
    _input.clear();
    setState(() => _inputText = '');
  }

  /// 中断当前生成再发送。桌面端的中断会把未发送的排队消息回填到电脑输入框,
  /// 这个副作用必须如实告知,不能藏。
  Future<void> _interruptAndSend() async {
    final desktop =
        ref.read(piSessionProvider).selectedSource?.isDesktop == true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('中断当前生成?'),
        content: Text(
          desktop
              ? '会停止电脑端正在进行的这一轮,然后发送你的消息。\n'
                    '电脑端尚未发送的排队消息会被放回它的输入框。'
              : '会停止正在进行的这一轮,然后发送你的消息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('中断并发送'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _send(delivery: PiDelivery.interrupt);
  }

  /// 每项是否显示时间标注(与上一条带时间的项间隔 >5 分钟)。
  List<bool> _timestampFlags(List<ChatItem> items) {
    final flags = List<bool>.filled(items.length, false);
    DateTime? prev;
    for (var i = 0; i < items.length; i++) {
      final time = timeOf(items[i]);
      if (time == null) continue;
      flags[i] = shouldShowTimestamp(prev, time);
      prev = time;
    }
    return flags;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      piSessionProvider.select((s) => s.revision),
      (_, _) => _scrollToBottomIfNear(),
    );

    final state = ref.watch(piSessionProvider);
    final timestampFlags = _timestampFlags(state.items);
    // 首帧之后量一次;之后由 SizeChangedLayoutNotifier 驱动
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncComposerHeight());
    // 留 12dp 呼吸,免得最后一条消息贴着输入卡的圆角
    final listBottomInset = _composerHeight + 12;

    return Column(
      children: [
        _LivenessBanner(state: state),
        if (state.isCompacting) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          // 输入条**浮在**消息流之上,内容从它下面滚过去 —— 这才是「悬浮」。
          // 它原来是 Column 的兄弟节点,身后必然是 scaffold 的实色背景,
          // 所以无论怎么调都会看到一条白底。
          child: Stack(
            children: [
              if (!state.hasSession)
                const _NotConnectedView()
              else if (state.items.isEmpty)
                const _EmptyHint()
              else
                ListView.builder(
                  controller: _scroll,
                  // 底部留出输入卡的实测高度,免得最后一条消息被压在下面
                  padding: EdgeInsets.fromLTRB(12, 12, 12, listBottomInset),
                  // +1:待应答的扩展对话框作为列表最后一项,
                  // 跟着内容一起滚,而不是卡在输入条上方的孤儿位置
                  itemCount:
                      state.items.length +
                      (state.pendingUiRequest != null ? 1 : 0),
                  findChildIndexCallback: (key) {
                    final index = state.items.indexWhere(
                      (item) => ValueKey(item.key) == key,
                    );
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    if (index == state.items.length) {
                      final request = state.pendingUiRequest!;
                      return UiRequestCard(
                        key: ValueKey('ui-request-${request.id}'),
                        request: request,
                      );
                    }
                    final item = state.items[index];
                    final view = ChatItemView(
                      key: ValueKey(item.key),
                      item: item,
                    );
                    if (!timestampFlags[index]) return view;
                    return Column(
                      children: [
                        MessageTimestamp(time: timeOf(item)!),
                        view,
                      ],
                    );
                  },
                ),
              if (state.hasSession)
                Positioned(
                  right: 16,
                  // 抬到输入卡上方,不然会被它压住
                  bottom: listBottomInset,
                  child: ScrollToBottomButton(
                    controller: _scroll,
                    revision: state.revision,
                  ),
                ),
              // 输入永远开放:任意一端、任意时刻都能发消息和打断。
              // 唯一的门是"还没连上 bridge",那时整个界面都不在这条分支。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: NotificationListener<SizeChangedLayoutNotification>(
                  onNotification: (_) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _syncComposerHeight(),
                    );
                    return true;
                  },
                  child: SizeChangedLayoutNotifier(
                    key: _composerKey,
                    child: Composer(
                      controller: _input,
                      enabled: true,
                      streaming: state.isStreaming,
                      onSend: _send,
                      onSteer: () => _send(delivery: PiDelivery.steer),
                      onFollowUp: () => _send(delivery: PiDelivery.followUp),
                      onInterruptAndSend: _interruptAndSend,
                      onAbort: () => unawaited(
                        ref.read(piSessionProvider.notifier).abort(),
                      ),
                      onChanged: (text) => setState(() => _inputText = text),
                      quickPanel: QuickPanel(
                        inputText: _inputText,
                        onInsert: (text) {
                          _input.text = text;
                          _input.selection = TextSelection.collapsed(
                            offset: text.length,
                          );
                          setState(() => _inputText = text);
                        },
                        onSendPrompt: (text) {
                          // 快捷指令没有输入框可清,自己挡住连点
                          if (_sending) return;
                          setState(() => _sending = true);
                          unawaited(
                            ref
                                .read(piSessionProvider.notifier)
                                .sendPrompt(text)
                                .whenComplete(() {
                                  if (mounted) setState(() => _sending = false);
                                }),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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

    // Center 包 SCSV:内容矮时居中,内容比视口高时(横屏/大字体/长错误
    // 文本)可以滚 —— 否则 Column 在 Stack 的定高里没有出路,直接纵向溢出。
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 44,
                backgroundColor: colors.surfaceContainerHighest,
                foregroundColor: colors.onSurfaceVariant,
                child: Icon(icon, size: 38),
              ),
              const SizedBox(height: 16),
              Text(message, style: Theme.of(context).textTheme.titleMedium),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: colors.error),
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
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('前往设置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话活跃度横幅。
///
/// **空闲且一切正常时完全不渲染** —— 这是"大方"最直接的动作:平时聊天区域
/// 上方没有任何 chrome。只有四种真正需要说话的情况才出现。
class _LivenessBanner extends ConsumerWidget {
  const _LivenessBanner({required this.state});

  final PiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final source = state.selectedSource;

    final queueParts = <String>[
      if (state.steeringQueue.isNotEmpty) '插队 ${state.steeringQueue.length}',
      if (state.followUpQueue.isNotEmpty) '排队 ${state.followUpQueue.length}',
    ];

    final (
      IconData icon,
      String text,
      Color bg,
      Color fg,
      Widget? action,
    ) = switch (state) {
      _ when source == null => (
        Icons.dashboard_customize_outlined,
        '还没有选择会话',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        TextButton(
          // maybeOf:ChatBody 被单独 pump 时(测试)没有外层 Scaffold,
          // 用 of() 会直接抛异常。
          onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
          child: const Text('选择会话'),
        ),
      ),
      _ when state.sessionWaking => (
        Icons.play_circle_outline,
        '正在唤醒 ${source.label}',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      // 「正在生成」**不占横幅**。这个状态本来就有三处更省地方的表达:
      // 顶栏的中断按钮、助手气泡里的打字指示器、输入框的「生成中 · 发送会插队」。
      // 再压一条 50dp 的横幅纯属浪费空间。
      // 压缩同理 —— 它下面紧跟着一条 LinearProgressIndicator。
      _ when !source.connected => (
        Icons.bedtime_outlined,
        '${source.label} 已休眠 · 发消息会自动唤醒',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
      // 一切正常:下面 text.isEmpty 会返回 SizedBox.shrink(),这里的颜色画不出来
      _ => (
        Icons.circle,
        '',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
        null,
      ),
    };

    // 一切正常:不渲染任何东西
    if (text.isEmpty && queueParts.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty)
              Row(
                children: [
                  if (state.isStreaming)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                      ),
                    )
                  else
                    Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: fg),
                    ),
                  ),
                  ?action,
                ],
              ),
            if (queueParts.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: text.isEmpty ? 0 : 4),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: fg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${queueParts.join(' · ')} — '
                        '${[...state.steeringQueue, ...state.followUpQueue].first}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 44,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.auto_awesome, size: 38),
              ),
              const SizedBox(height: 20),
              Text(
                '开始一段对话',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '给 pi 下达你的第一个指令,例如「看看当前目录结构」',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
