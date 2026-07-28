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
}
