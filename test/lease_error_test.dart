import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

/// bridge 用四种不同的措辞表达「你已经不在驱动了」。少认一种,
/// `_mutatingRequest` 就少一次自动强制重取 —— 用户看到的是一个
/// 点了没反应、重试也没反应的按钮。
///
/// 这些字符串的出处:
/// - `bridge/src/owner_lease.ts` → "a valid owner lease is required"
///   / "lease is missing, expired, or stale" / "source is controlled by another client"
/// - `bridge/src/server.ts` → "desktop TUI took over this session"
void main() {
  group('租约错误识别', () {
    bool isLeaseError(String error) =>
        PiSessionNotifier.debugIsLeaseError({'success': false, 'error': error});

    test('bridge 的四种控制权错误全部识别', () {
      expect(isLeaseError('a valid owner lease is required'), isTrue);
      expect(isLeaseError('lease is missing, expired, or stale'), isTrue);
      expect(isLeaseError('source is controlled by another client'), isTrue);
      expect(isLeaseError('desktop TUI took over this session'), isTrue);
    });

    test('无关错误不触发重取', () {
      expect(isLeaseError('cwd is not a directory'), isFalse);
      expect(isLeaseError('source command timed out'), isFalse);
      expect(
        isLeaseError('streaming_guard: source is streaming; abort first'),
        isFalse,
      );
      expect(isLeaseError('too many live sessions'), isFalse);
    });

    test('成功响应与非字符串错误都不算', () {
      expect(PiSessionNotifier.debugIsLeaseError({'success': true}), isFalse);
      expect(PiSessionNotifier.debugIsLeaseError(null), isFalse);
      expect(
        PiSessionNotifier.debugIsLeaseError({'success': false, 'error': 42}),
        isFalse,
      );
    });
  });
}
