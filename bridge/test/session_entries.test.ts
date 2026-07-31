import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { readEntriesPage } from "../src/session_entries.js";
import type { JsonObject } from "../src/hub_protocol.js";

const identity = (entry: JsonObject): JsonObject => entry;

/// 与 pager 一致的字节口径:逐条 JSON 字节求和(不含数组括号/逗号)。
const sumBytes = (entries: JsonObject[]): number =>
  entries.reduce((acc, e) => acc + Buffer.byteLength(JSON.stringify(e)), 0);

const idxOf = (id: unknown): number => Number(String(id).replace("e-", ""));

function writeFixture(entries: JsonObject[]): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-entries-"));
  const file = path.join(dir, "session.jsonl");
  const lines = [
    JSON.stringify({
      type: "session",
      version: 1,
      id: "sess-1",
      timestamp: "2026-01-01T00:00:00Z",
      cwd: "/tmp",
    }),
    ...entries.map((e) => JSON.stringify(e)),
  ];
  fs.writeFileSync(file, `${lines.join("\n")}\n`, "utf8");
  return file;
}

const msgEntry = (i: number, text: string): JsonObject => ({
  type: "message",
  id: `e-${i}`,
  parentId: i === 0 ? null : `e-${i - 1}`,
  timestamp: i + 1,
  message: { role: i % 2 === 0 ? "user" : "assistant", content: text, timestamp: i + 1 },
});

const cleanup = (file: string): void => {
  fs.rmSync(path.dirname(file), { recursive: true, force: true });
};

test("会话文件分页: tail 取最新一段,字节预算是硬的", async () => {
  const file = writeFixture(
    Array.from({ length: 100 }, (_, i) => msgEntry(i, "x".repeat(900))),
  );
  try {
    const budget = 10 * 1024;
    const page = await readEntriesPage(file, { mode: "tail", budgetBytes: budget, cap: identity });
    assert.ok(page.entries.length > 0, "tail 页不得为空");
    assert.ok(
      sumBytes(page.entries) <= budget,
      `tail 页必须落在预算内,实际 ${sumBytes(page.entries)}B`,
    );
    assert.equal(page.entries.at(-1)?.id, "e-99", "tail 必须以最新一条结尾");
    assert.equal(page.leafId, "e-99", "leafId 必须是文件里最后一条");
    assert.equal(page.hasMore, true, "100 条只放下一部分,必须报 hasMore");
    assert.equal(page.oldestId, page.entries[0]?.id);
  } finally {
    cleanup(file);
  }
});

test("会话文件分页: before 返回游标之前那段,不得与 tail 页重叠", async () => {
  const file = writeFixture(
    Array.from({ length: 100 }, (_, i) => msgEntry(i, "x".repeat(900))),
  );
  try {
    const budget = 10 * 1024;
    const tail = await readEntriesPage(file, { mode: "tail", budgetBytes: budget, cap: identity });
    const cursor = tail.oldestId!;
    const older = await readEntriesPage(file, {
      mode: "before",
      cursor,
      budgetBytes: budget,
      cap: identity,
    });

    assert.ok(older.entries.length > 0, "before 页不得为空");
    // 这条就是真机上抓到的缺陷:pi 忽略 before 返回全部,裁尾巴后每页相同。
    const tailIds = new Set(tail.entries.map((e) => String(e.id)));
    for (const entry of older.entries) {
      assert.ok(
        !tailIds.has(String(entry.id)),
        `before 页不得包含 tail 页里的 ${String(entry.id)}`,
      );
    }
    // 必须紧接在游标之前,才能与已显示内容接上。
    assert.equal(
      idxOf(older.entries.at(-1)?.id),
      idxOf(cursor) - 1,
      "before 页最后一条必须正好是游标的前一条",
    );
    assert.equal(older.leafId, "e-99", "leafId 仍是文件里最后一条");
  } finally {
    cleanup(file);
  }
});

test("会话文件分页: 连续 before 翻页必须单调后退,页间不重叠", async () => {
  const file = writeFixture(
    Array.from({ length: 200 }, (_, i) => msgEntry(i, "x".repeat(900))),
  );
  try {
    const budget = 10 * 1024;
    const first = await readEntriesPage(file, { mode: "tail", budgetBytes: budget, cap: identity });
    let cursor = first.oldestId!;
    const seen = new Set(first.entries.map((e) => String(e.id)));
    let prevOldest = idxOf(cursor);

    for (let round = 1; round <= 5; round++) {
      const page = await readEntriesPage(file, {
        mode: "before",
        cursor,
        budgetBytes: budget,
        cap: identity,
      });
      assert.ok(page.entries.length > 0, `第 ${round} 页不得为空`);
      for (const entry of page.entries) {
        const id = String(entry.id);
        assert.ok(!seen.has(id), `第 ${round} 页重复返回了 ${id}(翻页没有推进)`);
        seen.add(id);
      }
      const oldest = idxOf(page.oldestId);
      assert.ok(
        oldest < prevOldest,
        `第 ${round} 页必须比上一页更早:${oldest} 应小于 ${prevOldest}`,
      );
      assert.ok(
        sumBytes(page.entries) <= budget,
        `第 ${round} 页必须落在预算内,实际 ${sumBytes(page.entries)}B`,
      );
      prevOldest = oldest;
      cursor = page.oldestId!;
    }
    // 5 页 + 首屏都不重叠,说明确实一路往前走了。
    assert.ok(seen.size > first.entries.length * 5, "累计条数应随翻页增长");
  } finally {
    cleanup(file);
  }
});

test("会话文件分页: since 正向翻页,nextSinceId 可串成链", async () => {
  const file = writeFixture(
    Array.from({ length: 60 }, (_, i) => msgEntry(i, "x".repeat(900))),
  );
  try {
    const budget = 8 * 1024;
    const page1 = await readEntriesPage(file, {
      mode: "since",
      cursor: "e-0",
      budgetBytes: budget,
      cap: identity,
    });
    assert.ok(page1.entries.length > 0);
    assert.equal(idxOf(page1.entries[0]?.id), 1, "since 必须从游标之后第一条开始");
    assert.ok(sumBytes(page1.entries) <= budget);
    assert.equal(page1.hasMore, true);

    const page2 = await readEntriesPage(file, {
      mode: "since",
      cursor: page1.nextSinceId!,
      budgetBytes: budget,
      cap: identity,
    });
    assert.equal(
      idxOf(page2.entries[0]?.id),
      idxOf(page1.entries.at(-1)?.id) + 1,
      "第二页必须紧接第一页,不漏不重",
    );
  } finally {
    cleanup(file);
  }
});

test("会话文件分页: since 的 tipId 是上边界,翻页 run 不受源增长影响", async () => {
  const file = writeFixture(
    Array.from({ length: 60 }, (_, i) => msgEntry(i, "x".repeat(200))),
  );
  try {
    const page = await readEntriesPage(file, {
      mode: "since",
      cursor: "e-0",
      tipId: "e-10",
      budgetBytes: 1024 * 1024,
      cap: identity,
    });
    assert.equal(
      page.entries.at(-1)?.id,
      "e-10",
      "tipId 之后的不得进入本页",
    );
    assert.equal(page.tipId, "e-10");
  } finally {
    cleanup(file);
  }
});

test("会话文件分页: 游标不存在时明确报 cursorNotFound", async () => {
  const file = writeFixture(Array.from({ length: 10 }, (_, i) => msgEntry(i, "x")));
  try {
    for (const mode of ["before", "since"] as const) {
      const page = await readEntriesPage(file, {
        mode,
        cursor: "does-not-exist",
        budgetBytes: 8 * 1024,
        cap: identity,
      });
      assert.equal(page.cursorNotFound, true, `${mode} 模式必须报游标不存在`);
    }
    const tail = await readEntriesPage(file, {
      mode: "tail",
      budgetBytes: 8 * 1024,
      cap: identity,
    });
    assert.equal(tail.cursorNotFound, false, "tail 没有游标,不该报不存在");
  } finally {
    cleanup(file);
  }
});

test("会话文件分页: 巨型单条不让页变空,且 cap 回调真的被用来算预算", async () => {
  // 真机实测:50MB 会话里有 35 条 compaction 单条超 64KiB,最大 576KB。
  const huge = {
    type: "compaction",
    id: "e-5",
    parentId: "e-4",
    timestamp: 6,
    summary: "S".repeat(300_000),
    details: { observations: ["O".repeat(100_000)] },
  } satisfies JsonObject;
  const entries: JsonObject[] = Array.from({ length: 10 }, (_, i) =>
    i === 5 ? huge : msgEntry(i, "x".repeat(900)),
  );
  const file = writeFixture(entries);
  try {
    const budget = 10 * 1024;
    // cap = identity:巨型单条远超预算,但页不能是空的。
    const raw = await readEntriesPage(file, {
      mode: "before",
      cursor: "e-6",
      budgetBytes: budget,
      cap: identity,
    });
    assert.ok(raw.entries.length >= 1, "巨型单条也必须至少返回一条,不能空页");

    // cap 折叠后:同样的预算能装下更多条,证明预算是按封顶后的形态算的。
    const folded = await readEntriesPage(file, {
      mode: "before",
      cursor: "e-6",
      budgetBytes: budget,
      cap: (entry) => {
        const size = Buffer.byteLength(JSON.stringify(entry));
        if (size <= 64 * 1024) return entry;
        return { id: entry.id, type: entry.type, timestamp: entry.timestamp, contentTruncated: true };
      },
    });
    assert.ok(
      folded.entries.length > raw.entries.length,
      `封顶后应能装更多条:folded=${folded.entries.length} raw=${raw.entries.length}`,
    );
    assert.ok(
      sumBytes(folded.entries) <= budget,
      `封顶后必须落在预算内,实际 ${sumBytes(folded.entries)}B`,
    );
    const foldedHuge = folded.entries.find((e) => e.id === "e-5");
    assert.equal(foldedHuge?.contentTruncated, true, "巨型单条必须是被折叠的那份");
  } finally {
    cleanup(file);
  }
});
