import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

/// 内置斜杠命令(/compact)的识别。
///
/// 存在的全部意义是守住边界:pi 的 session.prompt() 只解析**扩展注册**的命令,
/// 内置命令发过去就是一句字面文本,模型会当普通话来读。所以识别错了有两个方向
/// 的坏 —— 把命令当文本发出去(没压缩),或把普通句子当命令(误压缩)。
void main() {
  group('parseBuiltinCommand', () {
    test('裸 /compact', () {
      final invocation = PiSessionNotifier.parseBuiltinCommand('/compact');
      expect(invocation, isNotNull);
      expect(invocation!.name, 'compact');
      expect(invocation.argument, isNull);
    });

    test('/compact 带自定义要求', () {
      final invocation = PiSessionNotifier.parseBuiltinCommand(
        '/compact 保留报错信息和文件路径',
      );
      expect(invocation!.name, 'compact');
      expect(invocation.argument, '保留报错信息和文件路径');
    });

    test('命令名与参数之间的空白容许有多个', () {
      final invocation = PiSessionNotifier.parseBuiltinCommand(
        '/compact   保留重点  ',
      );
      expect(invocation!.argument, '保留重点');
    });

    test('/compacting 不是 /compact', () {
      // 前缀误配是最常见的命令解析 bug。
      expect(PiSessionNotifier.parseBuiltinCommand('/compacting'), isNull);
    });

    test('句子里出现 /compact 不算命令', () {
      expect(PiSessionNotifier.parseBuiltinCommand('请帮我 /compact 一下'), isNull);
    });

    test('不在开放名单里的内置命令不拦', () {
      // new / resume / fork / clone 永不开放 —— 那会换掉人在电脑上正用的会话。
      // 它们走 prompt 通道也比被误拦强。
      expect(PiSessionNotifier.parseBuiltinCommand('/new'), isNull);
      expect(PiSessionNotifier.parseBuiltinCommand('/resume'), isNull);
    });

    test('扩展命令不拦', () {
      expect(PiSessionNotifier.parseBuiltinCommand('/pipilot'), isNull);
    });

    test('只有斜杠', () {
      expect(PiSessionNotifier.parseBuiltinCommand('/'), isNull);
    });

    test('普通文本', () {
      expect(PiSessionNotifier.parseBuiltinCommand('compact 一下'), isNull);
    });
  });

  group('SlashCommand.isBuiltin', () {
    test('builtin 源', () {
      expect(
        const SlashCommand(name: 'compact', source: 'builtin').isBuiltin,
        isTrue,
      );
    });

    test('扩展命令默认不是 builtin', () {
      expect(const SlashCommand(name: 'commit').isBuiltin, isFalse);
    });
  });
}
