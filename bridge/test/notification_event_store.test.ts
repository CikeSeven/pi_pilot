import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createNotificationEvent, type NotificationEventV1 } from "../src/notification_event.js";
import { NotificationEventStore } from "../src/notification_event_store.js";
import { loadBridgeIdentity, rotateEventEpoch } from "../src/notification_identity.js";

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-notify-"));
}

const BRIDGE_ID = "bridge-test";
const EPOCH = "epoch-1";

function makeEvent(
  store: NotificationEventStore,
  overrides: Partial<Parameters<typeof createNotificationEvent>[0]> = {},
): NotificationEventV1 {
  return createNotificationEvent({
    bridgeInstallationId: BRIDGE_ID,
    eventEpoch: EPOCH,
    sequence: store.nextSequence(),
    type: "task_completed",
    presentation: { title: "task done", privacy: "generic" },
    ...overrides,
  });
}

// --- 基础持久化 -------------------------------------------------------------

test("appended events survive a reload with identical eventId and sequence", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  const first = makeEvent(store);
  assert.equal(store.appendEvent(first), true);
  const second = makeEvent(store, { type: "input_required" });
  assert.equal(store.appendEvent(second), true);
  store.close();

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  assert.equal(reopened.tip(), 2);
  const restored = reopened.range(0, 2);
  assert.deepEqual(
    restored.map((event) => [event.sequence, event.eventId]),
    [
      [first.sequence, first.eventId],
      [second.sequence, second.eventId],
    ],
  );
  reopened.close();
});

test("sequence never regresses across restarts", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  for (let i = 0; i < 5; i++) store.appendEvent(makeEvent(store));
  store.close();

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  assert.equal(reopened.nextSequence(), 6);
  reopened.close();
});

// --- 崩溃点:每个写边界前后各 kill 一次 -------------------------------------

test("a crash before fsync leaves the event pending and unclaimed", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({
    baseDir: dir,
    faultInjector: (stage) => {
      if (stage === "fsync") throw new Error("simulated power loss");
    },
  });
  store.load();
  const event = makeEvent(store);
  // 关键:落盘失败必须返回 false,调用方据此不宣称 persisted、不进发送队列。
  assert.equal(store.appendEvent(event), false);
  assert.equal(store.isDegraded(), true);
  assert.equal(store.stats().pending, 1);
  assert.equal(store.stats().writeFailures, 1);
  store.close();
});

test("pending events flush once the disk recovers", () => {
  const dir = tmpDir();
  let failing = true;
  const store = new NotificationEventStore({
    baseDir: dir,
    faultInjector: (stage) => {
      if (failing && stage === "fsync") throw new Error("disk full");
    },
  });
  store.load();
  const event = makeEvent(store);
  assert.equal(store.appendEvent(event), false);
  assert.equal(store.stats().pending, 1);

  failing = false;
  assert.equal(store.flushPending(), 1);
  assert.equal(store.stats().pending, 0);
  assert.equal(store.isDegraded(), false);
  store.close();

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  assert.equal(reopened.hasEventId(event.eventId), true);
  reopened.close();
});

test("a truncated tail line is skipped without wiping the store", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  const keep = makeEvent(store);
  store.appendEvent(keep);
  store.close();

  // 模拟断电:追加半条记录。
  const file = path.join(dir, "notification-outbox-v1.jsonl");
  fs.appendFileSync(file, '{"k":"event","c":"deadbeef","d":{"sche');

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  // 之前已校验的记录必须继续存在 —— 一次断电不该清空全部未读通知。
  assert.equal(reopened.hasEventId(keep.eventId), true);
  assert.equal(reopened.stats().corruptRecords, 1);
  reopened.close();
});

test("a checksum mismatch is treated as corruption", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  store.appendEvent(makeEvent(store));
  store.close();

  const file = path.join(dir, "notification-outbox-v1.jsonl");
  const original = fs.readFileSync(file, "utf8");
  // 篡改记录体但保留原 checksum:必须被识别为损坏而不是静默接受。
  fs.writeFileSync(file, original.replace('"title":"task done"', '"title":"tampered"'));

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  assert.equal(reopened.stats().corruptRecords, 1);
  assert.equal(reopened.tip(), 0);
  reopened.close();
});

test("compaction failure keeps the original log intact", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({
    baseDir: dir,
    maxEvents: 2,
    faultInjector: (stage) => {
      if (stage === "compact-rename") throw new Error("rename interrupted");
    },
  });
  store.load();
  const events = [];
  for (let i = 0; i < 4; i++) {
    const event = makeEvent(store);
    events.push(event);
    store.appendEvent(event);
  }
  store.close();

  // rename 失败后原日志必须仍可读出全部事件。
  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  for (const event of events) {
    assert.equal(reopened.hasEventId(event.eventId), true, `lost ${event.sequence}`);
  }
  reopened.close();
});

test("successful compaction preserves events and clears tombstones", () => {
  const dir = tmpDir();
  let clock = Date.parse("2026-08-01T00:00:00Z");
  const store = new NotificationEventStore({
    baseDir: dir,
    retentionMs: 1_000,
    now: () => clock,
  });
  store.load();
  const stale = makeEvent(store, { createdAt: new Date(clock).toISOString() });
  store.appendEvent(stale);
  clock += 10_000;
  const fresh = makeEvent(store, { createdAt: new Date(clock).toISOString() });
  store.appendEvent(fresh);

  assert.equal(store.pruneExpired(), 1);
  assert.equal(store.hasEventId(stale.eventId), false);
  assert.equal(store.hasEventId(fresh.eventId), true);
  assert.equal(store.compact(), true);
  store.close();

  const reopened = new NotificationEventStore({ baseDir: dir, now: () => clock });
  reopened.load();
  assert.equal(reopened.hasEventId(fresh.eventId), true);
  assert.equal(reopened.hasEventId(stale.eventId), false);
  reopened.close();
});

// --- 背压 -------------------------------------------------------------------

test("backpressure drops normal priority before high priority", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({
    baseDir: dir,
    maxPending: 2,
    faultInjector: (stage) => {
      if (stage === "fsync") throw new Error("stuck disk");
    },
  });
  store.load();
  store.appendEvent(makeEvent(store, { priority: "normal" }));
  store.appendEvent(makeEvent(store, { priority: "high" }));
  // 第三条挤掉队列里的 normal,而不是 high。
  store.appendEvent(makeEvent(store, { priority: "high" }));
  assert.equal(store.stats().droppedBackpressure, 1);
  assert.equal(store.stats().pending, 2);
  store.close();
});

// --- task generation 去重 ---------------------------------------------------

test("a generation completes only once so end and settled cannot double notify", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  store.beginGeneration("source-a", "gen-1");
  assert.equal(store.completeGeneration("gen-1", "event-1"), true);
  // agent_settled 紧随 agent_end 到达:第二次必须被拒绝。
  assert.equal(store.completeGeneration("gen-1", "event-2"), false);
  store.close();
});

test("in-flight generations survive a restart", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  store.beginGeneration("source-a", "gen-live");
  store.beginGeneration("source-b", "gen-done");
  store.completeGeneration("gen-done", "event-x");
  store.close();

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  const inFlight = reopened.inFlightGenerations().map((gen) => gen.taskGenerationId);
  assert.deepEqual(inFlight, ["gen-live"]);
  assert.equal(reopened.generationState("gen-done")?.state, "completed");
  reopened.close();
});

// --- ack 幂等 ---------------------------------------------------------------

test("acks are idempotent and never regress", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  store.recordAck("inst-a", EPOCH, 10);
  store.recordAck("inst-a", EPOCH, 5); // 迟到的旧 ack
  assert.equal(store.ackFor("inst-a")?.through, 10);
  store.close();

  const reopened = new NotificationEventStore({ baseDir: dir });
  reopened.load();
  assert.equal(reopened.ackFor("inst-a")?.through, 10);
  reopened.close();
});

test("multiple installations track independent cursors", () => {
  const dir = tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  store.recordAck("inst-a", EPOCH, 7);
  store.recordAck("inst-b", EPOCH, 3);
  assert.equal(store.ackFor("inst-a")?.through, 7);
  assert.equal(store.ackFor("inst-b")?.through, 3);
  store.close();
});

// --- 随机 kill/restart 循环 -------------------------------------------------

test("已 fsync 的事件在 200 轮随机重启后零丢失", () => {
  const dir = tmpDir();
  const persisted = new Set<string>();
  for (let round = 0; round < 200; round++) {
    const store = new NotificationEventStore({ baseDir: dir });
    store.load();
    // 每轮写 1-3 条后立刻「崩溃」(不 close,模拟进程被杀)。
    const count = 1 + (round % 3);
    for (let i = 0; i < count; i++) {
      const event = makeEvent(store);
      if (store.appendEvent(event)) persisted.add(event.eventId);
    }
  }
  const final = new NotificationEventStore({ baseDir: dir });
  final.load();
  for (const eventId of persisted) {
    assert.equal(final.hasEventId(eventId), true, `event ${eventId} was lost`);
  }
  assert.equal(final.stats().events >= persisted.size, true);
  final.close();
});

// --- 身份 -------------------------------------------------------------------

test("bridge identity is stable across loads but epoch can rotate", () => {
  const dir = tmpDir();
  const first = loadBridgeIdentity(dir);
  assert.equal(first.created, true);
  const second = loadBridgeIdentity(dir);
  assert.equal(second.created, false);
  assert.equal(second.identity.bridgeInstallationId, first.identity.bridgeInstallationId);
  assert.equal(second.identity.eventEpoch, first.identity.eventEpoch);

  const rotated = rotateEventEpoch(dir, second.identity);
  // 身份不变(还是同一台 Bridge),但事件世代换了。
  assert.equal(rotated.bridgeInstallationId, first.identity.bridgeInstallationId);
  assert.notEqual(rotated.eventEpoch, first.identity.eventEpoch);
  assert.equal(loadBridgeIdentity(dir).identity.eventEpoch, rotated.eventEpoch);
});

test("a malformed identity file is backed up rather than silently replaced", () => {
  const dir = tmpDir();
  const file = path.join(dir, "bridge-identity.json");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(file, "{ not json");
  const loaded = loadBridgeIdentity(dir);
  assert.equal(loaded.created, true);
  const backups = fs.readdirSync(dir).filter((name) => name.includes("corrupt"));
  assert.equal(backups.length, 1);
});

test("identity files are written with 0600 permissions", () => {
  const dir = tmpDir();
  loadBridgeIdentity(dir);
  const mode = fs.statSync(path.join(dir, "bridge-identity.json")).mode & 0o777;
  assert.equal(mode, 0o600);
});
