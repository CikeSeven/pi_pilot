import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../state/pi_session.dart';
import '../../common/app_sheet.dart';
import '../../common/sheet_navigator.dart';
import '../../theme/typography.dart';
import 'ansi_text.dart';
import 'message_timestamp.dart';

final _fence = RegExp(r'```(\w*)\n([\s\S]*?)```');

/// 消息长按菜单:复制/分享/复制代码块/分叉/复制输出。
Future<void> showMessageActions(
  BuildContext context,
  WidgetRef ref,
  ChatItem item,
) {
  final (icon, title, copyText) = switch (item) {
    UserItem i => (Icons.person_outline, '用户消息', i.text),
    AssistantItem i => (Icons.smart_toy_outlined, '助手消息', i.text),
    ToolItem i => (Icons.build_outlined, '工具 ${i.name}', stripAnsi(i.output)),
    BashItem i => (Icons.terminal, 'bash', stripAnsi(i.output)),
    SystemItem i => (Icons.info_outline, '系统提示', i.text),
    CustomItem i => (Icons.extension_outlined, i.customType, i.text),
    SummaryItem i => (Icons.compress, '摘要', i.summary),
  };
  final time = timeOf(item);
  final codeBlocks = item is AssistantItem
      ? _fence.allMatches(item.text).toList()
      : const <RegExpMatch>[];

  // 这里同步抓齐所有外部资源,闭包里绝不再碰传入的 context/ref:
  // sheet 存活期间,被长按的那条消息可能因远端回退/epoch 变更/重连重置
  // 被卸载,之后 sheet 一旦重建(键盘弹起最常见),对已 deactivate 的
  // element 调 Theme.of 就是 build 期红屏;对已 dispose 的 widget 用
  // ref 则直接抛 StateError。messenger / notifier 都是 app 级,永生。
  final hintColor = Theme.of(context).hintColor;
  final timeStyle = Theme.of(context).textTheme.bodySmall;
  final messenger = ScaffoldMessenger.of(context);
  final notifier = ref.read(piSessionProvider.notifier);

  void copy(BuildContext sheetContext, String text, String toast) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    Navigator.pop(sheetContext);
    messenger.showSnackBar(SnackBar(content: Text(toast)));
  }

  HapticFeedback.mediumImpact();
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => SafeArea(
      // 包一层是为了让 SheetHeader 拿到明确的关闭键 —— 之前这个面板
      // 除了下滑和点遮罩没有任何退出方式
      child: SheetNavigator(
        root: (_) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(
                title,
                actions: [
                  Icon(icon, size: 18, color: hintColor),
                  const SizedBox(width: 8),
                  if (time != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(formatTimeFull(time), style: timeStyle),
                    ),
                ],
              ),
              SheetGroup(
                children: [
                  if (copyText.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.copy_outlined),
                      title: Text(switch (item) {
                        ToolItem() || BashItem() => '复制输出',
                        _ => '复制全文',
                      }),
                      onTap: () => copy(sheetContext, copyText, '已复制'),
                    ),
                  if (item is BashItem && item.command.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.keyboard_command_key),
                      title: const Text('复制命令'),
                      onTap: () => copy(sheetContext, item.command, '已复制命令'),
                    ),
                  for (final (index, match) in codeBlocks.take(3).indexed)
                    ListTile(
                      leading: const Icon(Icons.code),
                      title: Text(
                        codeBlocks.length == 1 ? '复制代码块' : '复制代码块 ${index + 1}',
                      ),
                      subtitle: match[1]!.isEmpty
                          ? null
                          : Text(
                              match[1]!,
                              style: AppType.monoLabel(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => copy(sheetContext, match[2]!, '已复制代码'),
                    ),
                  if (copyText.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.share_outlined),
                      title: const Text('分享'),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        SharePlus.instance.share(ShareParams(text: copyText));
                      },
                    ),
                ],
              ),
              if (item is UserItem && item.entryId != null)
                SheetGroup(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.undo_rounded),
                      title: const Text('回到这里重新开始'),
                      subtitle: const Text('这之后的内容会移出当前分支,两端同步;随时可以再切回来'),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        final ok = await notifier.navigateTo(item.entryId!);
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(ok ? '已回到这条消息' : '回退失败'),
                            action: ok
                                ? null
                                : SnackBarAction(
                                    label: '重试',
                                    onPressed: () => unawaited(
                                      notifier.navigateTo(item.entryId!),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.fork_right),
                      title: const Text('从此处另开一个会话'),
                      subtitle: const Text('新建一个会话文件,当前会话保持原样'),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        final ok = await notifier.forkFrom(item.entryId!);
                        messenger.showSnackBar(
                          SnackBar(content: Text(ok ? '已另开一个会话' : '操作失败或被取消')),
                        );
                      },
                    ),
                  ],
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}
