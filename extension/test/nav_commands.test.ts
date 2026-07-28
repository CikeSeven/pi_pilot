import assert from "node:assert/strict";
import test from "node:test";
import {
  parseNavArgs,
  runNavigate,
  undoTargetId,
  type NavRuntime,
  type TreeNodeLike,
} from "../src/nav_commands.js";

/// pi 真实的树形状:`{ entry: { id, type, message: { role } }, children }`。
/// 之前这个 fixture 用的是 relay 压平后的线上形态,于是把 `undoTargetId` 的
/// 形状 bug 一起掩盖掉了。
function msg(id: string, role: "user" | "assistant", children: TreeNodeLike[] = []): TreeNodeLike {
  return { entry: { id, type: "message", message: { role } }, children };
}

const TREE: TreeNodeLike[] = [
  msg("u1", "user", [
    msg("a1", "assistant", [msg("u2", "user", [msg("a2", "assistant")])]),
    // 另一条分支:不在当前 leaf 的路径上,不该被撤销选中
    msg("u9", "user"),
  ]),
];

test("parseNavArgs takes the first token and treats empty as undo", () => {
  assert.deepEqual(parseNavArgs("  entry-7  "), { entryId: "entry-7" });
  assert.deepEqual(parseNavArgs("entry-7 extra words"), { entryId: "entry-7" });
  assert.deepEqual(parseNavArgs("   "), {});
  assert.deepEqual(parseNavArgs(""), {});
});

test("undo targets the last user message on the current branch only", () => {
  assert.equal(undoTargetId(TREE, "a2"), "u2");
  // leaf 在第一轮的助手消息上 → 撤销回到 u1,而不是另一分支的 u9
  assert.equal(undoTargetId(TREE, "a1"), "u1");
  assert.equal(undoTargetId(TREE, "unknown"), undefined);
  assert.equal(undoTargetId(undefined, "a2"), undefined);
  assert.equal(undoTargetId(TREE, undefined), undefined);
});

function fakeRuntime(overrides: Partial<NavRuntime> = {}): {
  runtime: NavRuntime;
  calls: string[];
} {
  const calls: string[] = [];
  const runtime: NavRuntime = {
    abort: () => calls.push("abort"),
    waitForIdle: async () => {
      calls.push("waitForIdle");
    },
    navigateTree: async (targetId) => {
      calls.push(`navigateTree:${targetId}`);
      return {};
    },
    getTree: () => TREE,
    getLeafId: () => "a2",
    ...overrides,
  };
  return { runtime, calls };
}

test("navigate aborts and waits for idle before touching the tree", async () => {
  const { runtime, calls } = fakeRuntime();
  const result = await runNavigate(runtime, "u1");
  assert.equal(result.ok, true);
  // navigateTree 自己不中断,会在活着的回合底下重写 messages —— 顺序是硬要求
  assert.deepEqual(calls, ["abort", "waitForIdle", "navigateTree:u1"]);
});

test("navigate with no entry id resolves the undo target", async () => {
  const { runtime, calls } = fakeRuntime();
  const result = await runNavigate(runtime, undefined);
  assert.equal(result.ok, true);
  assert.deepEqual(calls, ["abort", "waitForIdle", "navigateTree:u2"]);
});

test("the undo target is re-read after the abort settles", async () => {
  // 中断期间 pi 会把部分助手消息和排队消息落盘,树因此长出新节点。
  // 用中断前的快照定位会多丢一截用户没要求丢的内容。
  let afterAbort = false;
  const grown: TreeNodeLike[] = [
    msg("u1", "user", [
      msg("a1", "assistant", [
        msg("u2", "user", [msg("a2", "assistant", [msg("u3", "user")])]),
      ]),
    ]),
  ];
  const { runtime, calls } = fakeRuntime({
    waitForIdle: async () => {
      calls.push("waitForIdle");
      afterAbort = true;
    },
    getTree: () => (afterAbort ? grown : TREE),
    getLeafId: () => (afterAbort ? "u3" : "a2"),
  });
  const result = await runNavigate(runtime, undefined);
  assert.equal(result.ok, true);
  assert.deepEqual(calls, ["abort", "waitForIdle", "navigateTree:u3"]);
});

test("navigate reports when there is nothing to undo, without aborting", async () => {
  const { runtime, calls } = fakeRuntime({ getTree: () => [] });
  const result = await runNavigate(runtime, undefined);
  assert.equal(result.ok, false);
  assert.match(result.error ?? "", /撤销/);
  // 没有目标就不该白白打断一个正在跑的回合
  assert.deepEqual(calls, []);
});

test("navigate surfaces cancellation and errors instead of claiming success", async () => {
  const cancelled = await runNavigate(
    fakeRuntime({ navigateTree: async () => ({ cancelled: true }) }).runtime,
    "u1",
  );
  assert.equal(cancelled.ok, false);
  assert.equal(cancelled.cancelled, true);

  const failed = await runNavigate(
    fakeRuntime({
      navigateTree: async () => {
        throw new Error("boom");
      },
    }).runtime,
    "u1",
  );
  assert.equal(failed.ok, false);
  assert.equal(failed.error, "boom");
});

test("navigate passes the editor text back when pi returns the original message", async () => {
  const { runtime } = fakeRuntime({
    navigateTree: async () => ({ editorText: "原来的消息" }) as never,
  });
  const result = await runNavigate(runtime, "u2");
  assert.equal(result.ok, true);
  assert.equal(result.editorText, "原来的消息");
});
