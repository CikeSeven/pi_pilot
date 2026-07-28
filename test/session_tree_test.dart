import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';

void main() {
  SessionTreeNode node(
    String id, {
    List<SessionTreeNode> children = const [],
  }) => SessionTreeNode(id: id, type: 'message', children: children);

  test('currentPath 从根走到 leaf', () {
    final tree = SessionTree(
      roots: [
        node(
          'a',
          children: [
            node('b', children: [node('c')]),
            node('d'),
          ],
        ),
      ],
      leafId: 'c',
    );
    expect(tree.currentPath, {'a', 'b', 'c'});
  });

  test('leaf 不存在时路径为空', () {
    final tree = SessionTree(roots: [node('a')], leafId: 'zzz');
    expect(tree.currentPath, isEmpty);
  });

  test('forkPoints 找出多子分支节点', () {
    final tree = SessionTree(
      roots: [
        node(
          'a',
          children: [
            node('b', children: [node('c'), node('d')]),
            node('e'),
          ],
        ),
      ],
      leafId: 'c',
    );
    expect(tree.forkPoints.map((n) => n.id), ['a', 'b']);
  });

  /// 会话树是一条长单链(没有分叉时深度 == 消息数),所以任何按 children 递归的
  /// 写法都会在千条会话上爆栈。桌面端的深度上限是 2000,这里按上限之上取样。
  group('长单链不爆栈', () {
    SessionTree deepChain(int depth, {required String leafId}) {
      var current = SessionTreeNode(id: 'n$depth', type: 'message');
      for (var i = depth - 1; i >= 1; i--) {
        current = SessionTreeNode(
          id: 'n$i',
          type: 'message',
          children: [current],
        );
      }
      return SessionTree(roots: [current], leafId: leafId);
    }

    test('currentPath 走完 2500 层', () {
      final tree = deepChain(2500, leafId: 'n2500');
      final path = tree.currentPath;
      expect(path.length, 2500);
      expect(path.contains('n1'), isTrue);
      expect(path.contains('n2500'), isTrue);
    });

    test('leaf 在链中间时只包含到它为止的那一段', () {
      final tree = deepChain(2500, leafId: 'n1200');
      expect(tree.currentPath.length, 1200);
      expect(tree.currentPath.contains('n1201'), isFalse);
    });

    test('forkPoints 扫完 2500 层且单链没有分叉点', () {
      expect(deepChain(2500, leafId: 'n2500').forkPoints, isEmpty);
    });
  });

  /// 「每一条消息都能回退」的判定。toolResult 也是 type == 'message',
  /// 所以它同样可回退 —— 这正是用户要的。
  group('canNavigate 覆盖所有消息角色', () {
    SessionTreeNode typed(String type, {String? role}) =>
        SessionTreeNode(id: 'x', type: type, role: role);

    test('用户/AI/工具结果都能回退', () {
      expect(typed('message', role: 'user').canNavigate, isTrue);
      expect(typed('message', role: 'assistant').canNavigate, isTrue);
      expect(typed('message', role: 'toolResult').canNavigate, isTrue);
    });

    test('分支摘要能回退,压缩点不能', () {
      expect(typed('branch_summary').canNavigate, isTrue);
      // 压缩点是历史的一部分,不是可落脚的回合边界
      expect(typed('compaction').canNavigate, isFalse);
    });
  });

  /// 折叠标记只在桌面端真的剪了枝时才出现;默认必须是 0,
  /// 否则界面会凭空多出「省略 N 条」。
  test('collapsedBefore 默认为 0', () {
    expect(node('a').collapsedBefore, 0);
    expect(
      SessionTreeNode(
        id: 'a',
        type: 'message',
        collapsedBefore: 7,
      ).collapsedBefore,
      7,
    );
  });

  /// 工具信息是区分 toolResult / assistant 的关键 —— toolResult 没有文本预览,
  /// 只有 thinking+toolCall 的 assistant 回合预览也是空的。
  test('工具字段默认为空,可携带工具名与错误标记', () {
    expect(node('a').toolName, isNull);
    expect(node('a').tools, isEmpty);
    expect(node('a').isError, isFalse);

    const withTool = SessionTreeNode(
      id: 'a',
      type: 'message',
      role: 'toolResult',
      toolName: 'bash',
      isError: true,
    );
    expect(withTool.toolName, 'bash');
    expect(withTool.isError, isTrue);

    const withCalls = SessionTreeNode(
      id: 'b',
      type: 'message',
      role: 'assistant',
      tools: ['bash', 'read'],
    );
    expect(withCalls.tools, ['bash', 'read']);
  });
}
