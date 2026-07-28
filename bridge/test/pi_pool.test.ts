import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { loadConfig, type BridgeConfig } from "../src/config.js";
import { CommandQueue } from "../src/command_queue.js";
import { PiPool, sourceIdForSession, type PoolEntry } from "../src/pi_pool.js";
import { OwnerLeaseManager } from "../src/owner_lease.js";

const bridgeRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FAKE_PI = path.join(bridgeRoot, "test", "fixtures", "fake_pi_wrapper.sh");

function poolConfig(overrides: Partial<BridgeConfig> = {}): BridgeConfig {
  return { ...loadConfig(), maxLiveSessions: 2, sessionIdleTtlMs: 50, ...overrides };
}

interface Recorder {
  spawns: string[];
  exits: string[];
  closings: Array<[string, string]>;
  deaths: Array<[string, string]>;
  lines: Array<[string, string]>;
}

function recorder(
  watchers: (sourceId: string) => number = () => 0,
  pendingCount: (sourceId: string) => number = () => 0,
): { rec: Recorder; callbacks: ConstructorParameters<typeof PiPool>[1] } {
  const rec: Recorder = { spawns: [], exits: [], closings: [], deaths: [], lines: [] };
  return {
    rec,
    callbacks: {
      watchers,
      pendingCount,
      onSpawn: (entry: PoolEntry) => rec.spawns.push(entry.sourceId),
      onExit: (entry: PoolEntry) => rec.exits.push(entry.sourceId),
      onClosing: (entry: PoolEntry, reason: string) => rec.closings.push([entry.sourceId, reason]),
      onDead: (entry: PoolEntry, reason: string) => rec.deaths.push([entry.sourceId, reason]),
      onLine: (entry: PoolEntry, line: string) => rec.lines.push([entry.sourceId, line]),
    },
  };
}

function withFakePi<T>(run: () => T): T {
  const previous = process.env.PIPILOT_PI_BIN;
  process.env.PIPILOT_PI_BIN = FAKE_PI;
  try {
    return run();
  } finally {
    if (previous === undefined) delete process.env.PIPILOT_PI_BIN;
    else process.env.PIPILOT_PI_BIN = previous;
  }
}

test("open attaches to the live process instead of respawning it", async () => {
  const { rec, callbacks } = recorder();
  const pool = new PiPool(poolConfig(), callbacks);
  try {
    const first = withFakePi(() => pool.open({ sessionId: "alpha", cwd: bridgeRoot }));
    const pid = first.proc.pid;
    assert.ok(pid);
    const second = withFakePi(() => pool.open({ sessionId: "alpha", cwd: bridgeRoot }));
    // 切回同一个会话必须复用同一个进程 —— 这正是「切换会话不打断生成」
    assert.equal(second, first);
    assert.equal(second.proc.pid, pid);
    assert.equal(rec.spawns.length, 1);
    assert.equal(pool.size, 1);
  } finally {
    await pool.shutdownAll();
  }
});

test("opening a second session leaves the first process untouched", async () => {
  const { callbacks } = recorder();
  const pool = new PiPool(poolConfig({ maxLiveSessions: 4 }), callbacks);
  try {
    const a = withFakePi(() => pool.open({ sessionId: "a", cwd: bridgeRoot }));
    const pidA = a.proc.pid;
    const b = withFakePi(() => pool.open({ sessionId: "b", cwd: bridgeRoot }));
    assert.notEqual(b.sourceId, a.sourceId);
    assert.equal(a.proc.alive, true);
    assert.equal(a.proc.pid, pidA);
    assert.equal(pool.size, 2);
  } finally {
    await pool.shutdownAll();
  }
});

test("eviction never targets a streaming session", async () => {
  const { rec, callbacks } = recorder();
  const pool = new PiPool(poolConfig({ maxLiveSessions: 2 }), callbacks);
  try {
    const a = withFakePi(() => pool.open({ sessionId: "a", cwd: bridgeRoot }));
    const b = withFakePi(() => pool.open({ sessionId: "b", cwd: bridgeRoot }));
    // a 更久没活动,但它正在生成 → 只能逐出 b
    pool.setStreaming(a.sourceId, true);
    pool.touch(b.sourceId);
    withFakePi(() => pool.open({ sessionId: "c", cwd: bridgeRoot }));
    // 逐出会等进程真的退出才松开 claim,所以 onClosing 是同步的、移除是异步的
    assert.deepEqual(rec.closings[0], [b.sourceId, "evicted for a new session"]);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(pool.has(a.sourceId), true);
    assert.equal(pool.has(b.sourceId), false);
  } finally {
    await pool.shutdownAll();
  }
});

test("a session claimed by the desktop cannot be opened by the pool", () => {
  const { callbacks } = recorder();
  const pool = new PiPool(poolConfig(), callbacks);
  // 两个 pi 进程打开同一个会话文件会互相覆写 —— 必须硬拒绝
  pool.claimExternal("shared", "desktop:test");
  assert.throws(
    () => pool.open({ sessionId: "shared", cwd: bridgeRoot }),
    /already open elsewhere/,
  );
  assert.equal(pool.size, 0);
});

test("idle candidates exclude watched, busy, and streaming sessions", async () => {
  let busy = 0;
  const { callbacks } = recorder(
    (sourceId) => (sourceId === "s:watched" ? 1 : 0),
    () => busy,
  );
  const pool = new PiPool(poolConfig({ sessionIdleTtlMs: 10 }), callbacks);
  try {
    const idle = withFakePi(() => pool.open({ sessionId: "idle", cwd: bridgeRoot }));
    withFakePi(() => pool.open({ sessionId: "watched", cwd: bridgeRoot }));
    const future = Date.now() + 10_000;
    assert.deepEqual(pool.idleCandidates(future), [idle.sourceId]);
    // 有在途请求就不能回收
    busy = 1;
    assert.deepEqual(pool.idleCandidates(future), []);
    busy = 0;
    // 正在生成就不能回收
    pool.setStreaming(idle.sourceId, true);
    assert.deepEqual(pool.idleCandidates(future), []);
  } finally {
    await pool.shutdownAll();
  }
});

test("eviction respects watchers and in-flight requests", async () => {
  // 有人在看第 1 个会话 → 即使它最久没活动,也不能被逐出
  const { callbacks } = recorder((sourceId) => (sourceId === "s:a" ? 1 : 0));
  const pool = new PiPool(poolConfig({ maxLiveSessions: 2 }), callbacks);
  try {
    const a = withFakePi(() => pool.open({ sessionId: "a", cwd: bridgeRoot }));
    const b = withFakePi(() => pool.open({ sessionId: "b", cwd: bridgeRoot }));
    withFakePi(() => pool.open({ sessionId: "c", cwd: bridgeRoot }));
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(pool.has(a.sourceId), true);
    assert.equal(pool.has(b.sourceId), false);
  } finally {
    await pool.shutdownAll();
  }
});

test("close holds the session claim until the process is really gone", async () => {
  const { callbacks } = recorder();
  const pool = new PiPool(poolConfig(), callbacks);
  const entry = withFakePi(() => pool.open({ sessionId: "held", cwd: bridgeRoot }));
  const closing = pool.close(entry.sourceId, "test");
  // 进程还没死 —— 这段窗口里绝不能为同一个会话文件再开一个 pi
  assert.throws(
    () => withFakePi(() => pool.open({ sessionId: "held", cwd: bridgeRoot })),
    /shutting down/,
  );
  await closing;
  // 关完之后可以重新打开
  const again = withFakePi(() => pool.open({ sessionId: "held", cwd: bridgeRoot }));
  assert.ok(again.proc.pid);
  await pool.shutdownAll();
});

test("rebind moves the claim when the process switches session files", async () => {
  const { callbacks } = recorder();
  const pool = new PiPool(poolConfig({ maxLiveSessions: 4 }), callbacks);
  try {
    const entry = withFakePi(() => pool.open({ sessionId: "old", cwd: bridgeRoot }));
    pool.rebind(entry.sourceId, "new");
    assert.equal(entry.spec.sessionId, "new");
    // 旧会话的 claim 已释放 → 可以另开一个进程持有它
    const revived = withFakePi(() => pool.open({ sessionId: "old", cwd: bridgeRoot }));
    assert.notEqual(revived.sourceId, entry.sourceId);
    // 新会话现在被占,别人不能再开
    assert.throws(
      () => pool.rebind(revived.sourceId, "new"),
      /already open elsewhere/,
    );
  } finally {
    await pool.shutdownAll();
  }
});

test("shutdownAll kills every process and clears claims", async () => {
  const { callbacks } = recorder();
  const pool = new PiPool(poolConfig({ maxLiveSessions: 4 }), callbacks);
  const a = withFakePi(() => pool.open({ sessionId: "a", cwd: bridgeRoot }));
  const b = withFakePi(() => pool.open({ sessionId: "b", cwd: bridgeRoot }));
  await pool.shutdownAll();
  assert.equal(pool.size, 0);
  assert.equal(a.proc.alive, false);
  assert.equal(b.proc.alive, false);
  // claim 已清空 → 同一会话可以重新开
  const again = withFakePi(() => pool.open({ sessionId: "a", cwd: bridgeRoot }));
  assert.ok(again.proc.pid);
  await pool.shutdownAll();
});

test("sourceIdForSession is stable across process restarts", () => {
  assert.equal(sourceIdForSession("abc"), "s:abc");
  assert.equal(sourceIdForSession("abc"), sourceIdForSession("abc"));
});

test("forced acquire steals the lease and bumps the fence strictly", () => {
  const leases = new OwnerLeaseManager();
  const first = leases.acquire("phone-a", 10_000);
  assert.equal(first.ok, true);
  assert.ok(first.ok);
  // 非强制:尊重现有持有者
  const polite = leases.acquire("phone-b", 10_000);
  assert.equal(polite.ok, false);
  // 强制:立刻抢走,并报告被抢的是谁
  const forced = leases.acquire("phone-b", 10_000, { force: true });
  assert.ok(forced.ok);
  assert.equal(forced.stolenFrom, "phone-a");
  assert.ok(forced.lease.fence > first.lease.fence);
  // 旧 fence 的在途命令必须作废
  assert.equal(
    leases.validate("phone-a", first.lease.leaseId, first.lease.fence).ok,
    false,
  );
});

test("the command queue serializes per source and isolates failures", async () => {
  const queue = new CommandQueue();
  const trace: string[] = [];
  const depths = new Map<string, number>();
  let maxSrcDepth = 0;
  const task = (key: string, name: string, ms: number) => async (): Promise<void> => {
    const depth = (depths.get(key) ?? 0) + 1;
    depths.set(key, depth);
    if (key === "src") maxSrcDepth = Math.max(maxSrcDepth, depth);
    trace.push(`${name}:enter`);
    await new Promise((resolve) => setTimeout(resolve, ms));
    trace.push(`${name}:exit`);
    depths.set(key, depth - 1);
  };

  const a = queue.run("src", task("src", "a", 40));
  const failing = queue
    .run("src", async () => {
      throw new Error("boom");
    })
    .catch(() => "handled");
  const b = queue.run("src", task("src", "b", 5));
  // 另一个 source 不受影响,可以并发
  const other = queue.run("other", task("other", "other", 10));

  await Promise.all([a, failing, b, other]);
  // 同一 source 上的时间窗严格不重叠
  assert.equal(maxSrcDepth, 1);
  assert.deepEqual(
    trace.filter((entry) => entry.startsWith("a") || entry.startsWith("b")),
    ["a:enter", "a:exit", "b:enter", "b:exit"],
  );
  // 抛错的命令不会卡住队尾
  assert.equal(await failing, "handled");
  // 不同 source 真的并行:other 在 a 还没结束时就跑完了
  assert.ok(trace.indexOf("other:exit") < trace.indexOf("a:exit"));
  assert.equal(queue.busy("src"), false);
});
