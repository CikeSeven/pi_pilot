/// 会话树一行排版的**纯数据**结果。从 [SessionTree] 算出行序列,
/// 语义与桌面 pi 的 `/tree`(tree-selector.js flattenTree)对齐:
///
/// - 单链不向右漂:只有多子节点才让子代缩进一级;
/// - 分叉后的第一代后裔再缩进一级(视觉分组);
/// - 含当前 leaf 的分支永远排在最前(root 与每一层 children 都是);
/// - 每个分叉子代带连接线(├ / └),分叉的后代带延续的竖线 gutter(│)。
///
/// 全部是**显式栈迭代**:会话树是一条长单链(没有分叉时深度 == 消息数),
/// 千条会话按 children 递归会爆栈。
library;

import '../../state/pi_session.dart';

/// 祖先竖线的延续标记:在某一级缩进上,左边的分支是否还没走完。
class TreeGutter {
  const TreeGutter(this.level, {required this.show});

  /// 竖线所在的缩进级(0 起)。
  final int level;

  /// true 画 │,false 留空(上一个分支已结束,但更深的位置可能还有线)。
  final bool show;
}

class TreeRowLayout {
  const TreeRowLayout({
    required this.node,
    required this.indent,
    required this.displayIndent,
    required this.isLast,
    required this.connector,
    required this.gutters,
  });

  final SessionTreeNode node;

  /// 逻辑缩进级(0 = 顶格)。
  final int indent;

  /// 渲染缩进级:多 root 时桌面端会把整棵树左移一档(虚拟根不占位)。
  /// gutter 的 level 也是这个坐标系。
  final int displayIndent;

  /// 是否是父节点的最后一个可见子分支(└);否则 ├。
  final bool isLast;

  /// 是否画连接线(分叉点的直接子代为 true;根与单链子代为 false)。
  /// 连接线的拐点在 displayIndent - 1 级。
  final bool connector;

  /// 祖先留下的竖线 gutter。
  final List<TreeGutter> gutters;
}

/// 把整棵树摊平成带连接线语义的行。
///
/// [leafId] 决定"当前分支优先"的排序;为空时退化为声明顺序。
List<TreeRowLayout> buildTreeRows(List<SessionTreeNode> roots, String? leafId) {
  // containsActive:子树里是否有当前 leaf。后序计算(子先于父),迭代实现。
  final containsActive = <SessionTreeNode, bool>{};
  {
    final all = <SessionTreeNode>[];
    final st = <SessionTreeNode>[];
    for (final root in roots.reversed) {
      st.add(root);
    }
    while (st.isNotEmpty) {
      final node = st.removeLast();
      all.add(node);
      for (final child in node.children.reversed) {
        st.add(child);
      }
    }
    for (var i = all.length - 1; i >= 0; i--) {
      final node = all[i];
      var has = leafId != null && node.id == leafId;
      if (!has) {
        for (final child in node.children) {
          if (containsActive[child] == true) {
            has = true;
            break;
          }
        }
      }
      containsActive[node] = has;
    }
  }

  List<SessionTreeNode> activeFirst(List<SessionTreeNode> children) {
    final prioritized = <SessionTreeNode>[];
    final rest = <SessionTreeNode>[];
    for (final child in children) {
      (containsActive[child] == true ? prioritized : rest).add(child);
    }
    return [...prioritized, ...rest];
  }

  final rows = <TreeRowLayout>[];
  final multipleRoots = roots.length > 1;
  // 桌面端把多 root 当成一个虚拟根的子代:缩进抬一级、带连接线。
  final orderedRoots = activeFirst(roots);
  final stack = <_Pending>[];
  for (var i = orderedRoots.length - 1; i >= 0; i--) {
    stack.add(
      _Pending(
        orderedRoots[i],
        multipleRoots ? 1 : 0,
        justBranched: multipleRoots,
        showConnector: multipleRoots,
        isLast: i == orderedRoots.length - 1,
        gutters: const [],
        isVirtualRootChild: multipleRoots,
      ),
    );
  }

  while (stack.isNotEmpty) {
    final item = stack.removeLast();
    final node = item.node;
    final connector = item.showConnector && !item.isVirtualRootChild;
    // 多 root 时虚拟根不占位:渲染比逻辑缩进左移一档。
    final displayIndent = multipleRoots
        ? (item.indent > 0 ? item.indent - 1 : 0)
        : item.indent;
    rows.add(
      TreeRowLayout(
        node: node,
        indent: item.indent,
        displayIndent: displayIndent,
        isLast: item.isLast,
        connector: connector,
        gutters: item.gutters,
      ),
    );

    final children = node.children;
    final multipleChildren = children.length > 1;
    // 含当前 leaf 的子分支排最前。
    final ordered = multipleChildren ? activeFirst(children) : children;
    // 与桌面端一致的三档:分叉子代 +1;分叉后第一代再 +1;单链不动。
    final int childIndent;
    if (multipleChildren) {
      childIndent = item.indent + 1;
    } else if (item.justBranched && item.indent > 0) {
      childIndent = item.indent + 1;
    } else {
      childIndent = item.indent;
    }
    // 当前节点画了连接线 → 后代在这一级留 gutter(└ 结束后不再延续)。
    final connectorLevel = displayIndent > 0 ? displayIndent - 1 : 0;
    final childGutters = connector
        ? [...item.gutters, TreeGutter(connectorLevel, show: !item.isLast)]
        : item.gutters;
    for (var i = ordered.length - 1; i >= 0; i--) {
      stack.add(
        _Pending(
          ordered[i],
          childIndent,
          justBranched: multipleChildren,
          showConnector: multipleChildren,
          isLast: i == ordered.length - 1,
          gutters: childGutters,
          isVirtualRootChild: false,
        ),
      );
    }
  }
  return rows;
}

class _Pending {
  const _Pending(
    this.node,
    this.indent, {
    required this.justBranched,
    required this.showConnector,
    required this.isLast,
    required this.gutters,
    required this.isVirtualRootChild,
  });

  final SessionTreeNode node;
  final int indent;
  final bool justBranched;
  final bool showConnector;
  final bool isLast;
  final List<TreeGutter> gutters;
  final bool isVirtualRootChild;
}
