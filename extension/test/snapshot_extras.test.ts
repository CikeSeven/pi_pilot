import assert from "node:assert/strict";
import test from "node:test";
import { buildTreeSummary, computeSessionStats } from "../src/relay.js";

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

test("buildTreeSummary drops itself when over budget", () => {
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
  assert.equal(buildTreeSummary(big), undefined);
});
