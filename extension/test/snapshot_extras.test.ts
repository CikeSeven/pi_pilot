import assert from "node:assert/strict";
import test from "node:test";
import { buildTreeSummary, computeSessionStats, navigableLeafId } from "../src/relay.js";

const usage = (input: number, output: number, total: number) => ({
  input,
  output,
  cacheRead: 0,
  cacheWrite: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total },
});

test("computeSessionStats sums assistant/toolResult usage like pi", () => {
  const entries = [
    { type: "message", message: { role: "user", content: "hi" } },
    {
      type: "message",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "ok" }, { type: "toolCall" }],
        usage: usage(100, 50, 0.5),
      },
    },
    { type: "message", message: { role: "toolResult", usage: usage(10, 5, 0.1) } },
    { type: "compaction", summary: "s", usage: usage(1, 1, 0.01) },
  ];
  const stats = computeSessionStats(entries, { tokens: 160, contextWindow: 1000, percent: 16 });
  assert.equal(stats.userMessages, 1);
  assert.equal(stats.assistantMessages, 1);
  assert.equal(stats.toolResults, 1);
  assert.equal(stats.toolCalls, 1);
  assert.equal(stats.totalMessages, 3);
  assert.deepEqual(stats.tokens, {
    input: 111,
    output: 56,
    cacheRead: 0,
    cacheWrite: 0,
    total: 167,
  });
  assert.ok(Math.abs((stats.cost as number) - 0.61) < 1e-9);
  assert.deepEqual(stats.contextUsage, { tokens: 160, contextWindow: 1000, percent: 16 });
});

test("buildTreeSummary compresses nodes with preview and role", () => {
  const tree = [
    {
      entry: {
        id: "a",
        parentId: null,
        type: "message",
        timestamp: 1,
        message: { role: "user", content: "x".repeat(300) },
      },
      children: [
        {
          entry: { id: "b", parentId: "a", type: "compaction", timestamp: 2 },
          children: [],
          label: "bookmark",
        },
      ],
    },
  ];
  const summary = buildTreeSummary(tree)!;
  assert.equal(summary.length, 1);
  const root = summary[0] as any;
  assert.equal(root.id, "a");
  assert.equal(root.role, "user");
  assert.ok(root.preview.length <= 121);
  assert.equal(root.children[0].id, "b");
  assert.equal(root.children[0].label, "bookmark");
});

/// 以前这里断言的是“超预算就返回 undefined” —— 而那正是「会话树不可用」的成因。
/// 千条规模的真实会话必然超预算,所以降级后必须仍然给出一棵树。
test("buildTreeSummary degrades instead of dropping the whole tree", () => {
  const big = Array.from({ length: 3000 }, (_, i) => ({
    entry: {
      id: `node-${i}`,
      parentId: null,
      type: "message",
      timestamp: i,
      message: { role: "user", content: "y".repeat(120) },
    },
    children: [],
  }));
  const summary = buildTreeSummary(big)!;
  assert.ok(summary, "超预算也不能返回 undefined");
  // 全部都是根节点,结构上无可剪,只能靠缩预览压下来
  assert.equal(summary.length, 3000);
  assert.ok(Buffer.byteLength(JSON.stringify(summary)) <= 256 * 1024);
  assert.equal((summary[0] as any).preview, undefined);
  // id 必须完整保留,否则回退会跳到错的节点
  assert.equal((summary[0] as any).id, "node-0");
  assert.equal((summary[2999] as any).id, "node-2999");
});

/// 预算是 WebSocket 的 UTF-8 字节,不能拿 JS string.length 代替。
/// 900 个中文节点的 code unit 数量仍在预算内,UTF-8 却会越界。降级必须按
/// 真字节数缩短预览,同时保住全部可回退 id。
test("buildTreeSummary measures Chinese previews in UTF-8 bytes", () => {
  const tree = Array.from({ length: 900 }, (_, i) => ({
    entry: {
      id: `节点-${i}`,
      parentId: null,
      type: "message",
      timestamp: i,
      message: { role: "user", content: "树".repeat(120) },
    },
    children: [],
  }));
  const summary = buildTreeSummary(tree)! as any[];
  const encoded = JSON.stringify(summary);

  assert.equal(summary.length, 900);
  assert.ok(Buffer.byteLength(encoded) <= 256 * 1024);
  // 120 字预览装不下,必须降级;按字符数计算会错误地保留 120 字。
  assert.ok(summary[0].preview.length < 121);
  assert.equal(summary[0].id, "节点-0");
  assert.equal(summary[899].id, "节点-899");
});

/// 长线性会话(没有分叉)是最常见的形态:一条单链几千节点。
test("buildTreeSummary prunes a long linear chain but keeps root/leaf/marks", () => {
  // 构造一条 4000 节点的单链,中间插一个压缩点和一个书签
  let node: any = { entry: { id: "leaf", type: "message", timestamp: 4000, message: { role: "assistant", content: "z".repeat(200) } }, children: [] };
  const leaf = node;
  for (let i = 3999; i >= 1; i--) {
    const isCompaction = i === 2000;
    const isBookmarked = i === 1500;
    node = {
      entry: isCompaction
        ? { id: `node-${i}`, type: "compaction", timestamp: i }
        : { id: `node-${i}`, type: "message", timestamp: i, message: { role: "user", content: "z".repeat(200) } },
      children: [node],
      ...(isBookmarked ? { label: "important" } : {}),
    };
  }
  const root = { entry: { id: "root", type: "message", timestamp: 0, message: { role: "user", content: "start" } }, children: [node] };

  const summary = buildTreeSummary([root])!;
  assert.ok(summary, "长单链也必须给出一棵树");
  assert.ok(Buffer.byteLength(JSON.stringify(summary)) <= 256 * 1024);

  // 展开看留下了什么
  const ids = new Set<string>();
  let collapsedTotal = 0;
  const walk = (n: any) => {
    ids.add(n.id);
    collapsedTotal += (n.collapsedBefore as number) ?? 0;
    for (const c of n.children ?? []) walk(c);
  };
  for (const r of summary) walk(r as any);

  assert.equal((summary[0] as any).id, "root");
  assert.ok(ids.has("leaf"), "叶子节点必须保留 —— 那是当前位置");
  assert.ok(ids.has("node-2000"), "压缩点不能被剪");
  assert.ok(ids.has("node-1500"), "书签节点不能被剪");
  // 确实剪掉了大量中间节点,且剪掉的数量记在 collapsedBefore 上
  assert.ok(ids.size < 1200, `应该剪掉大量节点,实际留了 ${ids.size}`);
  assert.equal(ids.size + collapsedTotal, 4001, "保留数 + 折叠数必须等于原总数");
});

/// 小会话不该被剪,也不该出现折叠标记。
test("buildTreeSummary leaves a small tree intact", () => {
  const tree = [
    {
      entry: { id: "a", type: "message", timestamp: 1, message: { role: "user", content: "hi" } },
      children: [
        {
          entry: { id: "b", type: "message", timestamp: 2, message: { role: "assistant", content: "yo" } },
          children: [],
        },
      ],
    },
  ];
  const summary = buildTreeSummary(tree)! as any[];
  assert.equal(summary[0].id, "a");
  assert.equal(summary[0].preview, "hi");
  assert.equal(summary[0].children[0].id, "b");
  assert.equal(summary[0].children[0].preview, "yo");
  assert.equal(summary[0].children[0].collapsedBefore, undefined);
});

test("navigableLeafId 把噪音叶子重映射到最近的可导航祖先", () => {
  const msg = (id: string, children: any[] = []) => ({
    entry: { id, type: "message", parentId: undefined },
    children,
  });
  const noise = (id: string, parentId: string, children: any[] = []) => ({
    entry: { id, type: "custom", customType: "msg-meta", parentId },
    children,
  });

  // 叶子本身可导航:原样返回(生成中的情形)
  const tree1 = [msg("m1", [msg("m2")])];
  assert.equal(navigableLeafId(tree1, "m2"), "m2");

  // 叶子是 msg-meta custom:回到父级 message(生成一停的情形)
  const tree2 = [msg("m1", [msg("m2", [noise("c1", "m2")])])];
  assert.equal(navigableLeafId(tree2, "c1"), "m2");

  // 连续两个噪音:一路向上走
  const tree3 = [msg("m1", [noise("c1", "m1", [noise("c2", "c1")])])];
  assert.equal(navigableLeafId(tree3, "c2"), "m1");

  // leaf 不在树里 / 为空:归 null,App 端不落假位置
  assert.equal(navigableLeafId(tree1, "zzz"), null);
  assert.equal(navigableLeafId(tree1, null), null);
});
