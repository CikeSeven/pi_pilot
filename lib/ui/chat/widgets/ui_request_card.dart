import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pi_session.dart';

/// 扩展对话框卡片(select/confirm/input/editor)。
/// owner 可交互应答;observer 只读展示。
class UiRequestCard extends ConsumerStatefulWidget {
  const UiRequestCard({super.key, required this.request});

  final UiRequest request;

  @override
  ConsumerState<UiRequestCard> createState() => _UiRequestCardState();
}

class _UiRequestCardState extends ConsumerState<UiRequestCard> {
  late final TextEditingController _input = TextEditingController(
    text: widget.request.prefill ?? '',
  );
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _respond({
    String? value,
    bool? confirmed,
    bool cancelled = false,
  }) async {
    setState(() => _busy = true);
    final ok = await ref
        .read(piSessionNotifierProvider)
        ?.respondUi(value: value, confirmed: confirmed, cancelled: cancelled);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok != true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('应答失败,这个对话框可能已经超时')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 只有 headless 源能在手机上应答:桌面对话框必须在电脑的 TUI 里回
    final canAnswer = ref.watch(
      piSessionProvider.select((s) => s.selectedSource?.isHeadless == true),
    );
    final request = widget.request;

    // 需要用户操作时这是屏幕上最重要的东西,但**不靠阴影**表达 ——
    // tertiary 是 vibrant 方案旋转出的独立色相,整块实色自己就够跳。
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      color: colors.tertiaryContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: colors.tertiary,
                  foregroundColor: colors.onTertiary,
                  child: const Icon(Icons.extension_rounded, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    request.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onTertiaryContainer,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (canAnswer)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    tooltip: '取消',
                    icon: const Icon(Icons.close),
                    onPressed: () => _respond(cancelled: true),
                  ),
              ],
            ),
            if (request.message != null) ...[
              const SizedBox(height: 4),
              Text(
                request.message!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onTertiaryContainer,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (!canAnswer)
              Text(
                '请在电脑端的 pi 里应答这个对话框',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onTertiaryContainer,
                ),
              )
            else
              switch (request.method) {
                'select' => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in request.options)
                      ActionChip(
                        label: Text(option),
                        backgroundColor: colors.tertiary,
                        labelStyle: TextStyle(color: colors.onTertiary),
                        onPressed: _busy ? null : () => _respond(value: option),
                      ),
                  ],
                ),
                'confirm' => Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _respond(confirmed: false),
                      child: const Text('否'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : () => _respond(confirmed: true),
                      child: const Text('是'),
                    ),
                  ],
                ),
                _ => Column(
                  children: [
                    TextField(
                      controller: _input,
                      minLines: request.method == 'editor' ? 3 : 1,
                      maxLines: request.method == 'editor' ? 8 : 3,
                      decoration: InputDecoration(
                        hintText: request.placeholder ?? '输入…',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_respond(value: _input.text)),
                        child: const Text('提交'),
                      ),
                    ),
                  ],
                ),
              },
          ],
        ),
      ),
    );
  }
}
