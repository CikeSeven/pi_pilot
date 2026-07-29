import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/ui/sessions/devices_page.dart';

/// 抽屉列的是「电脑上开着的 pi 窗口」，标题要让人认得出是哪个窗口。
///
/// pi 只在你显式命名会话时才写 `session_info.name`，所以大多数时候是 null。
/// 之前一律显示「未命名会话」，整列长得一模一样，等于没有标签。
void main() {
  group('窗口标题', () {
    test('有会话名就用会话名', () {
      expect(
        windowTitleFor(cwd: '/home/u/proj', sessionName: '重构 UI'),
        '重构 UI',
      );
    });

    test('会话名是空白等于没有，退回目录名', () {
      expect(windowTitleFor(cwd: '/home/u/proj', sessionName: '   '), 'proj');
      expect(windowTitleFor(cwd: '/home/u/proj', sessionName: ''), 'proj');
      expect(windowTitleFor(cwd: '/home/u/proj', sessionName: null), 'proj');
    });

    test('不同目录的窗口标题必须互不相同', () {
      final a = windowTitleFor(cwd: '/home/u/PiPilot', sessionName: null);
      final b = windowTitleFor(
        cwd: '/home/u/PiPilot/bridge',
        sessionName: null,
      );
      expect(a, 'PiPilot');
      expect(b, 'bridge');
      expect(a, isNot(b));
    });

    test('末尾斜杠与根目录不会拿到空标题', () {
      expect(windowTitleFor(cwd: '/home/u/proj/', sessionName: null), 'proj');
      expect(windowTitleFor(cwd: '/', sessionName: null), 'pi 窗口');
      expect(windowTitleFor(cwd: null, sessionName: null), 'pi 窗口');
    });
  });
}
