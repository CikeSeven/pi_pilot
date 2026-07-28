import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../common/app_sheet.dart';
import '../../common/sheet_navigator.dart';
import '../../theme/semantic_colors.dart';
import '../../theme/shapes.dart';
import 'quick_switch_sheet.dart';

/// 当前会话面板:点顶栏标题进入。
///
/// 把原来分散的三个入口(模型弹窗、思考档位弹窗、埋在设置页第 5 段的同一组
/// 开关)收敛到一处。上下文占用也在这里,不再需要顶栏那条等宽芯片。
Future<void> showSessionSheet(BuildContext context, WidgetRef ref) {
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => const SafeArea(
      // 弹窗自己持有页面栈:模型/档位是二级页,选完 pop 回这里
      child: SheetNavigator(root: _sessionSheetRoot),
    ),
  );
}

Widget _sessionSheetRoot(BuildContext context) => const _SessionSheetBody();

class _SessionSheetBody extends ConsumerWidget {
  const _SessionSheetBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(piSessionProvider);
    final theme = Theme.of(context);
    final piColors = PiColors.of(context);
    final percent = state.contextUsage?.percent;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(state.sessionName ?? '当前会话'),
          if (state.cwd case final cwd?)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                cwd,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (percent != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card(
                color: percent >= 80
                    ? piColors.warningContainer
                    : theme.colorScheme.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '上下文占用',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          Text('$percent%', style: theme.textTheme.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(PiShape.xs),
                        child: LinearProgressIndicator(
                          value: (percent / 100).clamp(0.0, 1.0),
                          minHeight: 8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SheetGroup(
            title: '运行设置',
            children: [
              ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('模型'),
                subtitle: Text(state.modelName ?? '未知'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => SheetNavigator.of(
                  context,
                ).push((_) => const ModelPickerPage()),
              ),
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('思考档位'),
                subtitle: Text(state.thinkingLevel ?? '未知'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => SheetNavigator.of(
                  context,
                ).push((_) => const ThinkingPickerPage()),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
