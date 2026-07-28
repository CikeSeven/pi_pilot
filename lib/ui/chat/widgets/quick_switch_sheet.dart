import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';
import '../../common/app_sheet.dart';
import '../../common/sheet_navigator.dart';
import '../../theme/typography.dart';

/// 模型与思考强度的选择页。
///
/// 它们是**会话面板里的二级页**,不是独立弹窗 —— 选完 `SheetNavigator.pop()`
/// 回到会话面板,而不是把整摞弹窗关掉。之前那版是 `Navigator.pop` + 重新
/// `showAppSheet`,不但用了正在卸载的 context,选完还什么都不剩。
///
/// 用 `ref.watch` 而不是 `ref.read`:作为常驻页面,选完之后勾要立刻挪位置。
class ModelPickerPage extends ConsumerStatefulWidget {
  const ModelPickerPage({super.key});

  @override
  ConsumerState<ModelPickerPage> createState() => _ModelPickerPageState();
}

class _ModelPickerPageState extends ConsumerState<ModelPickerPage> {
  // future 必须在 initState 里建好:provider 每次写状态(setModel 成功、
  // 流式消息)都会触发 rebuild,在 build 里新建 future 会让 FutureBuilder
  // 退回 loading 并反复打 RPC,sheet 关闭动画期间尤其吵。
  late final Future<List<ModelInfo>> _future = ref
      .read(piSessionProvider.notifier)
      .getAvailableModels();

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(piSessionProvider.notifier);
    final current = ref.watch(piSessionProvider.select((s) => s.modelName));
    return FutureBuilder<List<ModelInfo>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final models = snapshot.data!;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHeader('切换模型'),
              if (models.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('没有可用模型'),
                )
              else
                SheetGroup(
                  children: [
                    for (final model in models)
                      _PickerTile(
                        selected: model.name == current,
                        title: model.name,
                        subtitle: model.provider,
                        onTap: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          // 回到会话面板,而不是关掉整个弹窗
                          SheetNavigator.of(context).pop();
                          final ok = await notifier.setModel(
                            model.provider,
                            model.id,
                          );
                          if (!ok) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: const Text('切换模型失败'),
                                action: SnackBarAction(
                                  label: '重试',
                                  onPressed: () => unawaited(
                                    notifier.setModel(model.provider, model.id),
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                      ),
                  ],
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class ThinkingPickerPage extends ConsumerStatefulWidget {
  const ThinkingPickerPage({super.key});

  @override
  ConsumerState<ThinkingPickerPage> createState() => _ThinkingPickerPageState();
}

class _ThinkingPickerPageState extends ConsumerState<ThinkingPickerPage> {
  late final Future<List<String>> _future = ref
      .read(piSessionProvider.notifier)
      .getThinkingLevels();

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(piSessionProvider.notifier);
    final current = ref.watch(piSessionProvider.select((s) => s.thinkingLevel));
    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHeader('思考强度'),
              SheetGroup(
                children: [
                  for (final level in snapshot.data!)
                    _PickerTile(
                      selected: level == current,
                      title: level,
                      monoTitle: true,
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        SheetNavigator.of(context).pop();
                        final ok = await notifier.setThinkingLevel(level);
                        if (!ok) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: const Text('切换思考强度失败'),
                              action: SnackBarAction(
                                label: '重试',
                                onPressed: () =>
                                    unawaited(notifier.setThinkingLevel(level)),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.selected,
    required this.title,
    this.subtitle,
    this.monoTitle = false,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String? subtitle;
  final bool monoTitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        size: 22,
        color: selected ? colors.primary : colors.outlineVariant,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoTitle ? AppType.monoLabel() : null,
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: AppType.monoLabel(color: colors.onSurfaceVariant),
            ),
      onTap: onTap,
    );
  }
}
