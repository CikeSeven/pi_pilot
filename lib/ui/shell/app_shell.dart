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
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// `PopScope` 挂在 `Scaffold` 外面,所以 `Scaffold.maybeOf(context)` 在这一层
  /// 只会往上找、找不到下面那个 —— 必须用 key 才能拿到抽屉的 state。
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 抽屉是否展开。只为了驱动 [PopScope.canPop] 而存在。
  bool _drawerOpen = false;

  @override
  Widget build(BuildContext context) {
    // Material 的 Drawer 不注册任何返回键拦截(drawer.dart 里没有 PopScope),
    // 所以抽屉开着时按返回会直接落到根路由上 —— 表现就是一下退到桌面。
    // 这里把抽屉当成一层「可以被返回键关掉的东西」:开着时禁止 pop,
    // 拦到返回就只关抽屉;关上之后 canPop 恢复,再按一次才真的退出。
    return PopScope(
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 走到这里说明 pop 被 canPop 拦住了,唯一的原因就是抽屉开着。
        _scaffoldKey.currentState?.closeDrawer();
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: const SessionDrawer(),
        // 抽屉关闭时 Flutter 会把焦点还给 body 里第一个可聚焦节点 ——
        // 那正好是输入框,于是每次关抽屉键盘都会弹出来。这里显式收掉焦点。
        onDrawerChanged: (isOpen) {
          if (!isOpen) FocusManager.instance.primaryFocus?.unfocus();
          if (isOpen != _drawerOpen) setState(() => _drawerOpen = isOpen);
        },
        appBar: const ChatAppBar(),
        body: const ChatBody(),
      ),
    );
  }
}
