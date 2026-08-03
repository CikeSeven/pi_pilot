import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createNotificationEvent, type NotificationEventV1 } from "../src/notification_event.js";
import { NotificationEventStore } from "../src/notification_event_store.js";
import {
  coversContinuously,
  mergeSkipped,
  MAX_LIVE_BUFFER,
  NotificationSubscriptionManager,
  parseAckRequest,
  parseNotificationCursor,
  parseReceiptRequest,
  parseSubscribeRequest,
  type NotificationEventsPage,
} from "../src/notification_protocol.js";

const BRIDGE_ID = "bridge-test";
const EPOCH = "epoch-1";

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-proto-"));
}

function setup(): { store: NotificationEventStore; manager: NotificationSubscriptionManager } {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  const manager = new NotificationSubscriptionManager(store, BRIDGE_ID, EPOCH);
  return { store, manager };
}

function push(
  store: NotificationEventStore,
  overrides: Partial<Parameters<typeof createNotificationEvent>[0]> = {},
): NotificationEventV1 {
  const event = createNotificationEvent({
    bridgeInstallationId: BRIDGE_ID,
    eventEpoch: EPOCH,
    sequence: store.nextSequence(),
    type: "task_completed",
    presentation: { title: "done", privacy: "generic" },
    ...overrides,
  });
  assert.equal(store.appendEvent(event), true);
  return event;
}

function asPage(result: unknown): NotificationEventsPage {
  const page = result as NotificationEventsPage;
  assert.equal(page.type, "notification_events");
  return page;
}

// --- 请求解析 ---------------------------------------------------------------

test("subscribe requests reject malformed cursors and scopes", () => {
  assert.equal(parseSubscribeRequest(undefined), undefined);
  assert.equal(parseSubscribeRequest({ id: "", installationId: "i", scopeVersion: 1 }), undefined);
  assert.equal(
    parseSubscribeRequest({ id: "a", installationId: "i", cursor: { eventEpoch: 1 }, scopeVersion: 1 }),
    undefined,
  );
  assert.equal(
    parseSubscribeRequest({
      id: "a",
      installationId: "i",
      cursor: null,
      scopes: { eventTypes: ["nope"] },
      scopeVersion: 1,
    }),
    undefined,
  );
  const ok = parseSubscribeRequest({
    id: "a",
    installationId: "i",
    cursor: null,
    scopes: { sourceIds: ["s1"], eventTypes: ["task_completed"] },
    scopeVersion: 2,
    pageLimit: 5,
  });
  assert.equal(ok?.pageLimit, 5);
  assert.equal(ok?.backgroundElapsedMs, undefined);
  assert.equal(
    parseSubscribeRequest({
      id: 'b',
      installationId: 'i',
      scopeVersion: 1,
      backgroundElapsedMs: -1,
    }),
    undefined,
  );
  const bounded = parseSubscribeRequest({
    id: 'c',
    installationId: 'i',
    scopeVersion: 1,
    backgroundElapsedMs: Number.MAX_SAFE_INTEGER,
  });
  assert.equal(bounded?.backgroundElapsedMs, 24 * 60 * 60 * 1000);
  assert.equal(ok?.scopeVersion, 2);
});

test("page limit is clamped to the protocol maximum", () => {
  const parsed = parseSubscribeRequest({
    id: "a",
    installationId: "i",
    cursor: null,
    scopeVersion: 1,
    pageLimit: 100_000,
  });
  assert.equal(parsed?.pageLimit, 100);
});

test("cursor parsing distinguishes null from invalid", () => {
  assert.deepEqual(parseNotificationCursor(null), null);
  assert.deepEqual(parseNotificationCursor(undefined), null);
  assert.equal(parseNotificationCursor({ eventEpoch: "e", sequence: -1 }), undefined);
  assert.equal(parseNotificationCursor({ eventEpoch: "e", sequence: 1.5 }), undefined);
  assert.deepEqual(parseNotificationCursor({ eventEpoch: "e", sequence: 3 }), {
    eventEpoch: "e",
    sequence: 3,
  });
});

test("ack and receipt frames validate their fields", () => {
  assert.equal(parseAckRequest({ installationId: "i", eventEpoch: "e", through: -1 }), undefined);
  assert.deepEqual(parseAckRequest({ installationId: "i", eventEpoch: "e", through: 4 }), {
    installationId: "i",
    eventEpoch: "e",
    through: 4,
  });
  assert.equal(
    parseReceiptRequest({ installationId: "i", eventId: "e", state: "bogus" }),
    undefined,
  );
  const receipt = parseReceiptRequest({
    installationId: "i",
    eventId: "e",
    state: "display_confirmed",
    at: "2026-08-01T00:00:00Z",
  });
  assert.equal(receipt?.state, "display_confirmed");
});

// --- skippedRanges 合并与连续性 ---------------------------------------------

test("skipped sequences merge into compact ranges", () => {
  assert.deepEqual(mergeSkipped([]), []);
  assert.deepEqual(mergeSkipped([3]), [{ from: 3, through: 3 }]);
  assert.deepEqual(mergeSkipped([1, 2, 3, 7, 8, 10]), [
    { from: 1, through: 3 },
    { from: 7, through: 8 },
    { from: 10, through: 10 },
  ]);
});

test("continuity check rejects an unexplained gap", () => {
  const { store } = setup();
  const first = push(store);
  // sequence 2 既不在 events 里也不在 skippedRanges 里 -> 必须判为不连续。
  assert.equal(coversContinuously(0, 2, [first], []), false);
  assert.equal(coversContinuously(0, 2, [first], [{ from: 2, through: 2 }]), true);
});

// --- 固定 tip 与分页 --------------------------------------------------------

test("catch-up pages cover every sequence continuously", () => {
  const { store, manager } = setup();
  for (let i = 0; i < 5; i++) push(store);
  const page = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: null,
      scopes: {},
      scopeVersion: 1,
    }),
  );
  assert.equal(page.tip, 5);
  assert.equal(page.through, 5);
  assert.equal(page.events.length, 5);
  assert.equal(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
    true,
  );
});

test("tip stays fixed while new events arrive mid-pagination", () => {
  const { store, manager } = setup();
  for (let i = 0; i < 4; i++) push(store);
  const first = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: null,
      scopes: {},
      scopeVersion: 1,
      pageLimit: 2,
    }),
  );
  assert.equal(first.tip, 4);
  assert.equal(first.hasMore, true);
  assert.equal(first.through, 2);

  // 分页途中来了新事件:它绝不能改变本轮的固定上界。
  const late = push(store);
  manager.onEvent(late);

  const second = asPage(manager.nextPage("sub-1"));
  assert.equal(second.tip, 4, "固定 tip 被新事件改写了");
  assert.equal(second.through, 4);
  assert.equal(second.hasMore, false);
  // 新事件不在分页里,而在 live buffer 里等排空。
  assert.equal(second.events.some((event) => event.eventId === late.eventId), false);

  const drained = manager.drainLiveBuffer("sub-1");
  assert.ok("events" in drained);
  assert.deepEqual(drained.events.map((e) => e.sequence), [5]);
});

test("scope-excluded sequences are reported as skipped, not dropped", () => {
  const { store, manager } = setup();
  push(store, { sourceId: "source-a" });
  push(store, { sourceId: "source-b" });
  push(store, { sourceId: "source-a" });
  const page = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: null,
      scopes: { sourceIds: ["source-a"] },
      scopeVersion: 1,
    }),
  );
  assert.deepEqual(page.events.map((event) => event.sequence), [1, 3]);
  assert.deepEqual(page.skippedRanges, [{ from: 2, through: 2 }]);
  // 客户端据此可以安全 ack 到 3,而不会把 2 当成丢包。
  assert.equal(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
    true,
  );
});

test("event type scope filters independently of source", () => {
  const { store, manager } = setup();
  push(store, { type: "task_completed" });
  push(store, { type: "input_required" });
  const page = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: null,
      scopes: { eventTypes: ["input_required"] },
      scopeVersion: 1,
    }),
  );
  assert.deepEqual(page.events.map((event) => event.type), ["input_required"]);
  assert.deepEqual(page.skippedRanges, [{ from: 1, through: 1 }]);
});

test("a cursor exactly at the retention boundary still syncs normally", () => {
  let clock = Date.parse("2026-08-01T00:00:00Z");
  const store = new NotificationEventStore({
    baseDir: tmpDir(),
    retentionMs: 5_000,
    now: () => clock,
  });
  store.load();
  for (let i = 0; i < 3; i++) push(store, { createdAt: new Date(clock).toISOString() });
  clock += 60_000;
  const fresh = push(store, { createdAt: new Date(clock).toISOString() });
  assert.equal(store.pruneExpired(), 3);
  assert.equal(store.oldestAvailable(), 4);

  // cursor 刚好停在被回收段的末尾(3),下一条就是仍存在的 4 ——
  // 这种情况没有真正的历史缺口,不应该逼客户端 rebase。
  const manager = new NotificationSubscriptionManager(store, BRIDGE_ID, EPOCH, () => clock);
  const page = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: { eventEpoch: EPOCH, sequence: 3 },
      scopes: {},
      scopeVersion: 1,
    }),
  );
  assert.deepEqual(page.events.map((event) => event.eventId), [fresh.eventId]);
  assert.equal(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
    true,
  );
});

test("a hole in the middle of the range is reported as skipped", () => {
  let clock = Date.parse("2026-08-01T00:00:00Z");
  const store = new NotificationEventStore({
    baseDir: tmpDir(),
    retentionMs: 30_000,
    now: () => clock,
  });
  store.load();
  push(store, { createdAt: new Date(clock).toISOString() });
  push(store, { createdAt: new Date(clock).toISOString() });
  // 这一条很老,会单独被 TTL 回收,在区间中间留下一个洞。
  const doomed = push(store, { createdAt: new Date(clock - 60_000).toISOString() });
  push(store, { createdAt: new Date(clock).toISOString() });
  assert.equal(store.pruneExpired(), 1);
  assert.equal(store.hasEventId(doomed.eventId), false);
  assert.equal(store.oldestAvailable(), 1);

  const manager = new NotificationSubscriptionManager(store, BRIDGE_ID, EPOCH, () => clock);
  const page = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: { eventEpoch: EPOCH, sequence: 1 },
      scopes: {},
      scopeVersion: 1,
    }),
  );
  assert.deepEqual(page.events.map((event) => event.sequence), [2, 4]);
  assert.deepEqual(page.skippedRanges, [{ from: 3, through: 3 }]);
  // 客户端据此可以安全 ack 到 4,而不会把 3 当成丢包卡住。
  assert.equal(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
    true,
  );
});

test("byte budget splits a page before the count limit", () => {
  const { store, manager } = setup();
  // 单条事件被 title/body 上限收敛到约 1KB,所以要撞 64KiB 预算
  // 必须 title 和 body 同时拉满;只拉 title 的话 100 条也不到预算。
  for (let i = 0; i < 300; i++) {
    push(store, {
      presentation: { title: "x".repeat(200), body: "y".repeat(500), privacy: "session_name" },
    });
  }
  const page = asPage(
    manager.subscribe({
      id: "sub-1",
      installationId: "inst-a",
      cursor: null,
      scopes: {},
      scopeVersion: 1,
    }),
  );
  assert.equal(page.hasMore, true);
  assert.equal(page.events.length < 100, true, "字节预算未生效");
  assert.equal(JSON.stringify(page.events).length <= 64 * 1024 + 2048, true);
  // 分页仍需连续覆盖,字节截断不能制造无法解释的缺口。
  assert.equal(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
    true,
  );
});

// --- ready 语义 -------------------------------------------------------------

test("ready is withheld until catch-up finishes and the buffer drains", () => {
  const { store, manager } = setup();
  for (let i = 0; i < 3; i++) push(store);
  manager.subscribe({
    id: "sub-1",
    installationId: "inst-a",
    cursor: null,
    scopes: {},
    scopeVersion: 1,
    pageLimit: 1,
  });
  // 还有 2 页没发完:此时宣布 ready 会让客户端过早抑制兜底通知。
  assert.equal(manager.markReady("sub-1"), undefined);
  manager.nextPage("sub-1");
  assert.equal(manager.markReady("sub-1"), undefined);
  manager.nextPage("sub-1");

  const late = push(store);
  manager.onEvent(late);
  // buffer 里还有事件,仍不能 ready。
  assert.equal(manager.markReady("sub-1"), undefined);
  manager.drainLiveBuffer("sub-1");

  const ready = manager.markReady("sub-1");
  assert.equal(ready?.type, "notification_ready");
  assert.equal(ready?.bridgeInstallationId, BRIDGE_ID);
  assert.equal(ready?.through, 4);
  assert.equal(manager.isReady("sub-1"), true);
});

test("events after ready are pushed directly", () => {
  const { store, manager } = setup();
  manager.subscribe({
    id: "sub-1",
    installationId: "inst-a",
    cursor: null,
    scopes: {},
    scopeVersion: 1,
  });
  manager.markReady("sub-1");
  const event = push(store);
  const deliverable = manager.onEvent(event);
  assert.deepEqual(deliverable.get("sub-1")?.map((e) => e.sequence), [1]);
});

// --- live buffer 溢出 -------------------------------------------------------

test("live buffer overflow demands resync instead of dropping the head", () => {
  const { store, manager } = setup();
  push(store);
  manager.subscribe({
    id: "sub-1",
    installationId: "inst-a",
    cursor: null,
    scopes: {},
    scopeVersion: 1,
    pageLimit: 1,
  });
  // 停在 catch-up 中间,灌爆 buffer。
  for (let i = 0; i < MAX_LIVE_BUFFER + 10; i++) manager.onEvent(push(store));
  const drained = manager.drainLiveBuffer("sub-1");
  assert.equal((drained as { type?: string }).type, "notification_resync_required");
  // 溢出后不能悄悄 ready。
  assert.equal(manager.markReady("sub-1"), undefined);
});

// --- 过期事件抑制:完成通知落盘后断链积压,新任务已开跑(2026-08-02 事故)----

test("过期事件在 catch-up 分页里走 skippedRanges,覆盖连续性不破", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  // seq 1 过期(更新的任务已在它创建后开跑),seq 2 新鲜。
  const manager = new NotificationSubscriptionManager(
    store,
    BRIDGE_ID,
    EPOCH,
    Date.now,
    (event) => event.sequence === 1,
  );
  push(store, { createdAt: "2026-08-02T04:17:16.000Z" });
  push(store, { createdAt: "2026-08-02T04:18:30.000Z" });

  const request = parseSubscribeRequest({
    id: "sub-1",
    installationId: "inst-1",
    cursor: null,
    scopeVersion: 1,
  });
  assert.notEqual(request, undefined);
  const page = asPage(manager.subscribe(request));
  assert.deepEqual(page.events.map((event) => event.sequence), [2]);
  assert.deepEqual(page.skippedRanges, [{ from: 1, through: 1 }]);
  assert.ok(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
    "覆盖连续性被破坏,客户端会误判丢包",
  );
});

test("live buffer 里的过期事件被剔除,sequence 进 skipped", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  // seq 2 过期。
  const manager = new NotificationSubscriptionManager(
    store,
    BRIDGE_ID,
    EPOCH,
    Date.now,
    (event) => event.sequence === 2,
  );
  push(store); // seq 1:catch-up 占位,pageLimit=1 让订阅停在分页中
  const request = parseSubscribeRequest({
    id: "sub-1",
    installationId: "inst-1",
    cursor: null,
    scopeVersion: 1,
    pageLimit: 1,
  });
  assert.notEqual(request, undefined);
  manager.subscribe(request);
  const stale = push(store); // seq 2
  const fresh = push(store); // seq 3
  manager.onEvent(stale);
  manager.onEvent(fresh);

  const drained = manager.drainLiveBuffer("sub-1");
  assert.ok("events" in drained);
  assert.deepEqual(drained.events.map((event) => event.sequence), [3]);
  assert.deepEqual(drained.skipped, [2]);
});

test("后台窗口前的完成事件只推进 cursor,窗口后的完成仍投递", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  const now = Date.parse("2026-08-03T12:00:10.000Z");
  const manager = new NotificationSubscriptionManager(
    store,
    BRIDGE_ID,
    EPOCH,
    () => now,
  );
  push(store, {
    createdAt: "2026-08-03T12:00:04.999Z",
    sourceId: "source-a",
  });
  push(store, {
    type: "input_required",
    createdAt: "2026-08-03T12:00:04.000Z",
    sourceId: "source-a",
  });
  push(store, {
    createdAt: "2026-08-03T12:00:05.001Z",
    sourceId: "source-a",
  });

  const page = asPage(
    manager.subscribe({
      id: "sub-window",
      installationId: "inst-1",
      cursor: { eventEpoch: EPOCH, sequence: 0 },
      scopes: {},
      scopeVersion: 1,
      backgroundElapsedMs: 5_000,
    }),
  );

  assert.deepEqual(page.events.map((event) => event.sequence), [2, 3]);
  assert.deepEqual(page.skippedRanges, [{ from: 1, through: 1 }]);
  assert.ok(
    coversContinuously(page.fromExclusive, page.through, page.events, page.skippedRanges),
  );
});

test("旧客户端不传后台窗口时保持原 catch-up 行为", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  push(store, { createdAt: "2026-08-01T00:00:00.000Z" });
  const manager = new NotificationSubscriptionManager(
    store,
    BRIDGE_ID,
    EPOCH,
    () => Date.parse("2026-08-03T12:00:00.000Z"),
  );

  const page = asPage(
    manager.subscribe({
      id: "sub-legacy",
      installationId: "inst-1",
      cursor: { eventEpoch: EPOCH, sequence: 0 },
      scopes: {},
      scopeVersion: 1,
    }),
  );

  assert.deepEqual(page.events.map((event) => event.sequence), [1]);
  assert.deepEqual(page.skippedRanges, []);
});

test("后台窗口开始后的 live buffer 完成事件不受 catch-up 过滤", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  let clock = Date.parse("2026-08-03T12:00:10.000Z");
  push(store, { createdAt: new Date(clock - 10_000).toISOString() });
  const manager = new NotificationSubscriptionManager(
    store,
    BRIDGE_ID,
    EPOCH,
    () => clock,
  );
  manager.subscribe({
    id: "sub-live-window",
    installationId: "inst-1",
    cursor: { eventEpoch: EPOCH, sequence: 0 },
    scopes: {},
    scopeVersion: 1,
    pageLimit: 1,
    backgroundElapsedMs: 1_000,
  });

  clock += 100;
  const live = push(store, { createdAt: new Date(clock).toISOString() });
  manager.onEvent(live);
  const drained = manager.drainLiveBuffer("sub-live-window");

  assert.ok("events" in drained);
  assert.deepEqual(drained.events.map((event) => event.sequence), [2]);
  assert.deepEqual(drained.skipped, []);
});

// --- cursor 过期与 epoch ----------------------------------------------------

test("a cursor from a different epoch is rejected as store_reset", () => {
  const { store, manager } = setup();
  push(store);
  const result = manager.subscribe({
    id: "sub-1",
    installationId: "inst-a",
    cursor: { eventEpoch: "other-epoch", sequence: 1 },
    scopes: {},
    scopeVersion: 1,
  });
  assert.equal(result.type, "notification_cursor_expired");
  if (result.type === "notification_cursor_expired") {
    assert.equal(result.reason, "store_reset");
  }
});

test("a cursor older than retention gets an explicit rebase signal", () => {
  let clock = Date.parse("2026-08-01T00:00:00Z");
  const store = new NotificationEventStore({
    baseDir: tmpDir(),
    retentionMs: 1_000,
    now: () => clock,
  });
  store.load();
  for (let i = 0; i < 3; i++) push(store, { createdAt: new Date(clock).toISOString() });
  clock += 60_000;
  push(store, { createdAt: new Date(clock).toISOString() });
  store.pruneExpired();

  const manager = new NotificationSubscriptionManager(store, BRIDGE_ID, EPOCH, () => clock);
  const result = manager.subscribe({
    id: "sub-1",
    installationId: "inst-a",
    cursor: { eventEpoch: EPOCH, sequence: 0 },
    scopes: {},
    scopeVersion: 1,
  });
  assert.equal(result.type, "notification_cursor_expired");
  if (result.type === "notification_cursor_expired") {
    assert.equal(result.reason, "retention");
    assert.equal(result.oldestAvailable, 4);
  }
});

test("scopeVersion mismatch blocks cursor advancement", () => {
  const { store, manager } = setup();
  for (let i = 0; i < 3; i++) push(store);
  manager.subscribe({
    id: "sub-1",
    installationId: "inst-a",
    cursor: null,
    scopes: {},
    scopeVersion: 1,
    pageLimit: 1,
  });
  const stale = manager.nextPage("sub-1", 99);
  assert.equal(stale?.type, "notification_scope_changed");
});

// --- ack ---------------------------------------------------------------------

test("ack rejects epoch mismatch and out-of-range values", () => {
  const { store, manager } = setup();
  push(store);
  assert.deepEqual(manager.ack({ installationId: "i", eventEpoch: "other", through: 1 }), {
    ok: false,
    error: "epoch_mismatch",
  });
  assert.deepEqual(manager.ack({ installationId: "i", eventEpoch: EPOCH, through: 99 }), {
    ok: false,
    error: "ack_beyond_tip",
  });
  assert.deepEqual(manager.ack({ installationId: "i", eventEpoch: EPOCH, through: 1 }), {
    ok: true,
  });
  assert.equal(store.ackFor("i")?.through, 1);
});

test("acks from separate installations do not advance each other", () => {
  const { store, manager } = setup();
  for (let i = 0; i < 3; i++) push(store);
  manager.ack({ installationId: "inst-a", eventEpoch: EPOCH, through: 3 });
  manager.ack({ installationId: "inst-b", eventEpoch: EPOCH, through: 1 });
  assert.equal(store.ackFor("inst-a")?.through, 3);
  assert.equal(store.ackFor("inst-b")?.through, 1);
});

test("subscriptions are cleaned up per installation", () => {
  const { store, manager } = setup();
  push(store);
  manager.subscribe({
    id: "sub-a",
    installationId: "inst-a",
    cursor: null,
    scopes: {},
    scopeVersion: 1,
  });
  manager.subscribe({
    id: "sub-b",
    installationId: "inst-b",
    cursor: null,
    scopes: {},
    scopeVersion: 1,
  });
  assert.equal(manager.activeCount(), 2);
  manager.unsubscribeInstallation("inst-a");
  assert.equal(manager.activeCount(), 1);
});

// --- 断线重连补偿:这正是当前实现丢通知的场景 -------------------------------

test("一个在断线期间完整走完 streaming 的任务可以从 cursor 补回", () => {
  const { store, manager } = setup();
  // 手机在线,ack 到 1。
  push(store);
  manager.ack({ installationId: "inst-a", eventEpoch: EPOCH, through: 1 });

  // 手机断线。期间任务 idle -> streaming -> idle 完整发生,产生完成事件。
  const missed = push(store, { presentation: { title: "task finished offline", privacy: "generic" } });

  // 手机重连,带着旧 cursor。
  const page = asPage(
    manager.subscribe({
      id: "sub-2",
      installationId: "inst-a",
      cursor: { eventEpoch: EPOCH, sequence: 1 },
      scopes: {},
      scopeVersion: 1,
    }),
  );
  // 现有实现靠 hub_list_sessions 只能看到最终 idle,证明不了发生过完成事件;
  // 持久事件流可以。
  assert.deepEqual(page.events.map((event) => event.eventId), [missed.eventId]);
});
