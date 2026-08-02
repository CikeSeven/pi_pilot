import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/state/pi_session.dart';
import 'package:pi_pilot/ui/sessions/session_tree_screen.dart'
    show locateCurrentRow;
import 'package:pi_pilot/ui/sessions/tree_layout.dart' show buildTreeRows;

void main() {
  SessionTreeNode node(
    String id, {
    List<SessionTreeNode> children = const [],
    String type = 'message',
  }) => SessionTreeNode(id: id, type: type, children: children);

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

  locateRowCases();
  layoutCases(node);
}

void layoutCases(
  SessionTreeNode Function(
    String, {
    List<SessionTreeNode> children,
    String type,
  })
  node,
) {
  group('buildTreeRows(对齐桌面 /tree 语义)', () {
    test('单链全部顶格、无连接线', () {
      final rows = buildTreeRows([
        node(
          'a',
          children: [
            node('b', children: [node('c')]),
          ],
        ),
      ], 'c');
      expect(rows.map((r) => r.node.id), ['a', 'b', 'c']);
      expect(rows.map((r) => r.indent), [0, 0, 0]);
      expect(rows.every((r) => !r.connector), isTrue);
    });

    test('含 leaf 的分支排最前,分叉子代带连接线与缩进', () {
      // root -> fork -> [inactive(声明在前), active(含 leaf)]
      final rows = buildTreeRows([
        node(
          'root',
          children: [
            node(
              'fork',
              children: [
                node('inactive', children: [node('x')]),
                node('active', children: [node('leaf')]),
              ],
            ),
          ],
        ),
      ], 'leaf');
      expect(rows.map((r) => r.node.id), [
        'root',
        'fork',
        'active',
        'leaf',
        'inactive',
        'x',
      ]);
      final byId = {for (final r in rows) r.node.id: r};
      // 分叉子代:缩进 +1、带连接线;active 在前为 ├(isLast=false),另一个为 └。
      expect(byId['active']!.indent, 1);
      expect(byId['active']!.connector, isTrue);
      expect(byId['active']!.isLast, isFalse);
      expect(byId['inactive']!.indent, 1);
      expect(byId['inactive']!.connector, isTrue);
      expect(byId['inactive']!.isLast, isTrue);
      // 分叉后的第一代再缩进一级(视觉分组),active 分支的 gutter 延续。
      expect(byId['leaf']!.indent, 2);
      expect(
        byId['leaf']!.gutters.any((g) => g.level == 0 && g.show),
        isTrue,
        reason: 'active 分支还没结束,其后代要带延续竖线',
      );
      // inactive 是最后一个分支(└):其后代的 gutter 不再延续。
      expect(byId['x']!.gutters.any((g) => g.level == 0 && g.show), isFalse);
      expect(byId['x']!.indent, 2);
    });

    test('leaf 为空时保持声明顺序', () {
      final rows = buildTreeRows([
        node('fork', children: [node('b1'), node('b2')]),
      ], null);
      expect(rows.map((r) => r.node.id), ['fork', 'b1', 'b2']);
    });

    test('多 root 当作虚拟根的子代:抬一级、active root 在前', () {
      final rows = buildTreeRows([
        node('r1'),
        node('r2', children: [node('leaf')]),
      ], 'leaf');
      expect(rows.map((r) => r.node.id), ['r2', 'leaf', 'r1']);
      // 桌面端多 root 只抬缩进,不画连接线(虚拟根不可见)。
      expect(rows.first.indent, 1);
      expect(rows.first.connector, isFalse);
      // 分叉后的第一代再抬一级(虚拟根分叉 → justBranched)。
      expect(rows[1].node.id, 'leaf');
      expect(rows[1].indent, 2);
    });

    test('长单链不爆栈且全程顶格', () {
      var current = node('n2500');
      for (var i = 2499; i >= 1; i--) {
        current = node('n$i', children: [current]);
      }
      final rows = buildTreeRows([current], 'n2500');
      expect(rows.length, 2500);
      expect(rows.every((r) => r.indent == 0), isTrue);
      expect(rows.last.node.id, 'n2500');
    });
  });
}

void locateRowCases() {
  group('locateCurrentRow', () {
    test('leaf 在列表里:直接命中', () {
      expect(locateCurrentRow(['a', 'b', 'c'], 'b', {'a', 'b'}), 1);
    });

    test('leaf 不在摘要里:退到当前路径最后一行', () {
      expect(locateCurrentRow(['a', 'b', 'c'], 'zzz', {'a', 'b'}), 1);
    });

    test('leaf 为空:也退到当前路径最后一行', () {
      expect(locateCurrentRow(['a', 'b', 'c'], null, {'b', 'c'}), 2);
      expect(locateCurrentRow(['a', 'b', 'c'], '', {'a'}), 0);
    });

    test('leaf 和路径都找不到:返回 -1,不猜最后一行', () {
      expect(locateCurrentRow(['a', 'b', 'c'], 'zzz', {}), -1);
    });
  });
}
