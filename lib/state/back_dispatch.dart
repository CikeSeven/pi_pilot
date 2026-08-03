// Riverpod 3 把 StateProvider 挪进了 legacy 库。
import 'package:flutter_riverpod/legacy.dart';

/// 返回键分发所需的瞬时展开态。
///
/// 灵动岛 / 模型选择器的「展开」不再只是各自 State 里的私有字段:
/// AppShell 的 PopScope 要看这些状态决定 canPop,还要能通过置 false
/// 把它们收起来 —— 所以 provider 是单一事实来源,组件内部只是
/// watch + 回写。
final islandExpandedProvider = StateProvider<bool>((ref) => false);
final modelPickerExpandedProvider = StateProvider<bool>((ref) => false);

/// 会话抽屉的开合镜像。事实来源是 _ChatTab 的 AnimationController,
/// 这里只同步 0/非 0 的边沿,供 PopScope 判断。
final drawerOpenProvider = StateProvider<bool>((ref) => false);

/// 返回键应该落在谁身上。
enum BackTarget {
  /// 没有可收的东西:放行,退出应用。
  exit,

  /// 关会话抽屉。
  drawer,

  /// 切回对话页(当前在设备/设置页)。
  chatPage,

  /// 收起灵动岛。
  island,

  /// 收起模型选择器。
  modelPicker,
}

/// 返回键优先级:抽屉 > 切回对话页 > 灵动岛 > 模型选择器 > 退出。
///
/// 抽屉盖住了整个页面,先关它;不在对话页时岛上的展开态看不见,
/// 先切页;看得见的东西先收,最后才放行退出。
BackTarget resolveBackTarget({
  required bool drawerOpen,
  required int pageIndex,
  required bool islandExpanded,
  required bool modelPickerExpanded,
}) {
  if (drawerOpen) return BackTarget.drawer;
  if (pageIndex != 0) return BackTarget.chatPage;
  if (islandExpanded) return BackTarget.island;
  if (modelPickerExpanded) return BackTarget.modelPicker;
  return BackTarget.exit;
}
