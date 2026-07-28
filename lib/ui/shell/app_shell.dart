import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_body.dart';
import '../chat/widgets/chat_app_bar.dart';
import '../sessions/session_drawer.dart';

/// 应用外壳:持有 `Scaffold` 与抽屉。
///
/// 之前 `ChatScreen` 自己是 `Scaffold`,整个 app 只有一个持久界面、
/// 会话/目录/设置全塞在弹窗里。`Scaffold` 上移到这一层之后才有 `drawer:`
/// 可挂,对话页降级为纯 body。
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      drawer: const SessionDrawer(),
      // 抽屉关闭时 Flutter 会把焦点还给 body 里第一个可聚焦节点 ——
      // 那正好是输入框,于是每次关抽屉键盘都会弹出来。这里显式收掉焦点。
      onDrawerChanged: (isOpen) {
        if (!isOpen) FocusManager.instance.primaryFocus?.unfocus();
      },
      appBar: const ChatAppBar(),
      body: const ChatBody(),
    );
  }
}
