import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { NotificationDetector } from "../src/notification_detector.js";
import { NotificationEventStore } from "../src/notification_event_store.js";
import {
  NotificationSubscriptionManager,
  parseSubscribeRequest,
  type NotificationEventsPage,
} from "../src/notification_protocol.js";

const BRIDGE_ID = "bridge-test";
const EPOCH = "epoch-1";

function tmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-detect-"));
}

function setup(options: { dir?: string; privacy?: "generic" | "session_name" } = {}) {
  const dir = options.dir ?? tmpDir();
  const store = new NotificationEventStore({ baseDir: dir });
  store.load();
  const detector = new NotificationDetector({
    bridgeInstallationId: BRIDGE_ID,
    eventEpoch: EPOCH,
    store,
    ...(options.privacy !== undefined ? { privacy: options.privacy } : {}),
  });
  return { dir, store, detector };
}

// --- 完成事件去重:这是 agent_end + agent_settled 双通知的根因 ---------------

test("agent_end 与 agent_settled 对同一代次只生成一个完成事件", () => {
  const { detector } = setup();
  detector.onTaskStart("source-a");
  const first = detector.onTaskEnd("source-a");
  assert.notEqual(first, undefined);
  assert.equal(first?.persisted, true);
  assert.equal(first?.event.type, "task_completed");
  // agent_settled 紧随 agent_end 到达:必须被代次去重挡掉。
  assert.equal(detector.onTaskEnd("source-a"), undefined);
});

test("中断取消在飞代次:不产事件,后续 end/settled 也不补发", () => {
  const { detector } = setup();
  detector.onTaskStart("source-a");
  detector.onTaskAborted("source-a");
  // 中断后到达的 agent_settled 找不到在飞代次,绝不能凭空造事件。
  assert.equal(detector.onTaskEnd("source-a"), undefined);
});

test("中断的代次重启后不复活,下一轮正常完成不受影响", () => {
  const dir = tmpDir();
  const first = setup({ dir });
  first.detector.onTaskStart("source-a");
  first.detector.onTaskAborted("source-a");

  // 同一 journal 重建:cancelled 不是 in_flight,不能恢复成「任务还在跑」。
  const second = setup({ dir });
  assert.equal(second.store.inFlightGenerations().length, 0);
  assert.equal(second.detector.onTaskEnd("source-a"), undefined);

  // 下一轮正常完成:恰好一条,不多(中断没残留)不少(正常完成不受影响)。
  second.detector.onTaskStart("source-a");
  const done = second.detector.onTaskEnd("source-a");
  assert.equal(done?.event.type, "task_completed");
  assert.equal(second.detector.onTaskEnd("source-a"), undefined);
});

test("没有开始过的源上调中断是幂等空操作", () => {
  const { detector } = setup();
  detector.onTaskAborted("source-never-started");
  assert.equal(detector.onTaskEnd("source-never-started"), undefined);
});

test("重复的 agent_start 不开新代次", () => {
  const { detector } = setup();
  const first = detector.onTaskStart("source-a");
  const second = detector.onTaskStart("source-a");
  assert.equal(first, second);
});

test("没有 in-flight 代次时不凭空造完成事件", () => {
  const { detector } = setup();
  // Bridge 在任务中途启动,只看到结束边沿 —— 无法证明任务在本机跑过。
  assert.equal(detector.onTaskEnd("source-never-started"), undefined);
});

test("两个 source 的代次互不干扰", () => {
  const { detector } = setup();
  detector.onTaskStart("source-a");
  detector.onTaskStart("source-b");
  const a = detector.onTaskEnd("source-a");
  assert.equal(a?.event.sourceId, "source-a");
  // a 结束不该把 b 的代次也带走。
  assert.notEqual(detector.activeGenerationFor("source-b"), undefined);
  const b = detector.onTaskEnd("source-b");
  assert.equal(b?.event.sourceId, "source-b");
  assert.notEqual(a?.event.eventId, b?.event.eventId);
});

test("连续多轮任务各自生成一个完成事件", () => {
  const { detector } = setup();
  const ids: string[] = [];
  for (let round = 0; round < 3; round++) {
    detector.onTaskStart("source-a");
    const result = detector.onTaskEnd("source-a");
    assert.notEqual(result, undefined);
    ids.push(result!.event.eventId);
    // 每轮的 settled 重复都要被挡掉。
    assert.equal(detector.onTaskEnd("source-a"), undefined);
  }
  assert.equal(new Set(ids).size, 3);
});

// --- 重启恢复 ---------------------------------------------------------------

test("in-flight 代次跨重启恢复,结束事件沿用原代次", () => {
  const dir = tmpDir();
  const first = setup({ dir });
  const generationId = first.detector.onTaskStart("source-a");
  first.store.close();

  // 进程被杀,任务还在跑。
  const second = setup({ dir });
  assert.equal(second.detector.activeGenerationFor("source-a"), generationId);
  const result = second.detector.onTaskEnd("source-a");
  assert.equal(result?.event.taskGenerationId, generationId, "重启后开了新代次会重复通知");
  second.store.close();
});

test("已完成的代次在重启后不会复活", () => {
  const dir = tmpDir();
  const first = setup({ dir });
  first.detector.onTaskStart("source-a");
  first.detector.onTaskEnd("source-a");
  first.store.close();

  const second = setup({ dir });
  assert.equal(second.detector.activeGenerationFor("source-a"), undefined);
  // 重启后迟到的 settled 不能生成第二条完成通知。
  assert.equal(second.detector.onTaskEnd("source-a"), undefined);
  second.store.close();
});

test("adoptStreamingSource 让重启时只见 streaming 的 source 有代次可归属", () => {
  const { detector, store } = setup();
  const generationId = detector.adoptStreamingSource("source-a");
  assert.equal(generationId.startsWith("recovery-"), true);
  const result = detector.onTaskEnd("source-a");
  assert.equal(result?.event.taskGenerationId, generationId);
  assert.equal(store.generationState(generationId)?.state, "completed");
});

test("source epoch 切换作废旧代次,不串到新会话", () => {
  const { detector } = setup();
  detector.onTaskStart("source-a");
  detector.onSourceEpochChanged("source-a");
  assert.equal(detector.activeGenerationFor("source-a"), undefined);
  // 旧会话的结束边沿不该再生成通知。
  assert.equal(detector.onTaskEnd("source-a"), undefined);
});

// --- 等待输入 ---------------------------------------------------------------

test("同一 requestId 重复到达只生成一条等待输入事件", () => {
  const { detector } = setup();
  const first = detector.onInputRequired("req-1");
  assert.equal(first?.event.type, "input_required");
  assert.equal(first?.event.collapseKey, "input:req-1");
  assert.equal(detector.onInputRequired("req-1"), undefined);
  assert.equal(detector.pendingInputCount(), 1);
});

test("input_resolved 复用原 collapseKey 以便更新原通知", () => {
  const { detector } = setup();
  const required = detector.onInputRequired("req-1");
  const resolved = detector.onInputResolved("req-1");
  assert.equal(resolved?.event.type, "input_resolved");
  assert.equal(resolved?.event.collapseKey, required?.event.collapseKey);
  // resolved 是状态更新而非新提醒,优先级降级。
  assert.equal(resolved?.event.priority, "normal");
  assert.equal(detector.pendingInputCount(), 0);
});

test("没有对应 input_required 时不生成 resolved 噪声", () => {
  const { detector } = setup();
  assert.equal(detector.onInputResolved("req-unknown"), undefined);
});

test("input_required 默认高优先级", () => {
  const { detector } = setup();
  assert.equal(detector.onInputRequired("req-1")?.event.priority, "high");
});

// --- 隐私级别 ---------------------------------------------------------------

test("默认 generic 不把会话名写进通知标题", () => {
  const { detector } = setup();
  detector.onTaskStart("source-a");
  const result = detector.onTaskEnd("source-a", { sessionName: "客户的私密项目" });
  assert.equal(result?.event.presentation.privacy, "generic");
  assert.equal(result?.event.presentation.title.includes("私密"), false);
});

test("session_name 模式才显示会话名", () => {
  const { detector } = setup({ privacy: "session_name" });
  detector.onTaskStart("source-a");
  const result = detector.onTaskEnd("source-a", { sessionName: "重构任务" });
  assert.equal(result?.event.presentation.title, "重构任务 任务完成");
});

test("session_name 模式下拿不到会话名时退化为通用文案", () => {
  const { detector } = setup({ privacy: "session_name" });
  detector.onTaskStart("source-a");
  const result = detector.onTaskEnd("source-a");
  assert.equal(result?.event.presentation.title, "任务完成");
});

// --- 落盘失败传播 -----------------------------------------------------------

test("落盘失败时 persisted 为 false,调用方不得宣称已持久化", () => {
  const store = new NotificationEventStore({
    baseDir: tmpDir(),
    faultInjector: (stage) => {
      if (stage === "fsync") throw new Error("disk full");
    },
  });
  store.load();
  const detector = new NotificationDetector({
    bridgeInstallationId: BRIDGE_ID,
    eventEpoch: EPOCH,
    store,
  });
  detector.onTaskStart("source-a");
  const result = detector.onTaskEnd("source-a");
  assert.notEqual(result, undefined);
  assert.equal(result?.persisted, false);
  assert.equal(store.isDegraded(), true);
});

// --- sequence 单调 ----------------------------------------------------------

test("事件 sequence 严格单调递增", () => {
  const { detector } = setup();
  const sequences: number[] = [];
  for (let i = 0; i < 4; i++) {
    detector.onTaskStart(`source-${i}`);
    const result = detector.onTaskEnd(`source-${i}`);
    sequences.push(result!.event.sequence);
  }
  const input = detector.onInputRequired("req-1");
  sequences.push(input!.event.sequence);
  for (let i = 1; i < sequences.length; i++) {
    assert.equal(sequences[i]! > sequences[i - 1]!, true, `sequence 未递增: ${sequences}`);
  }
});

test("事件带稳定的 bridge 身份与 epoch", () => {
  const { detector } = setup();
  detector.onTaskStart("source-a");
  const result = detector.onTaskEnd("source-a");
  assert.equal(result?.event.bridgeInstallationId, BRIDGE_ID);
  assert.equal(result?.event.eventEpoch, EPOCH);
  assert.equal(result?.event.schema, 1);
});

// --- 过期完成通知判定:断链积压 + 新任务开跑(2026-08-02 事故)----------------

test("新任务开跑后,积压的旧完成事件判定为过期", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  let clock = Date.parse("2026-08-02T12:00:00.000Z");
  const detector = new NotificationDetector({
    bridgeInstallationId: BRIDGE_ID,
    eventEpoch: EPOCH,
    store,
    now: () => clock,
  });
  detector.onTaskStart("source-a");
  clock += 1000;
  const done = detector.onTaskEnd("source-a");
  assert.notEqual(done, undefined);
  // 尚无更新任务:不过期,迟到也该送达。
  assert.equal(detector.isStaleCompletion(done!.event), false);
  // 新任务开跑:旧完成事件立即过期。
  clock += 1000;
  detector.onTaskStart("source-a");
  assert.equal(detector.isStaleCompletion(done!.event), true);
  // 其他 source 不受影响;非完成类事件永不判过期。
  assert.equal(detector.isStaleCompletion({ ...done!.event, sourceId: "source-b" }), false);
  const input = detector.onInputRequired("req-1", { sourceId: "source-a" });
  assert.notEqual(input, undefined);
  assert.equal(detector.isStaleCompletion(input!.event), false);
});

test("重启后 in-flight 代次的开始时刻恢复,旧完成事件仍判过期", () => {
  const dir = tmpDir();
  let clock = Date.parse("2026-08-02T12:00:00.000Z");
  const make = () => {
    // generation 记录的 at 由 store 的时钟写入,恢复判定要与 detector 同源。
    const store = new NotificationEventStore({ baseDir: dir, now: () => clock });
    store.load();
    return new NotificationDetector({
      bridgeInstallationId: BRIDGE_ID,
      eventEpoch: EPOCH,
      store,
      now: () => clock,
    });
  };
  const first = make();
  first.onTaskStart("source-a");
  clock += 1000;
  const done = first.onTaskEnd("source-a");
  clock += 1000;
  first.onTaskStart("source-a"); // 新任务在跑,未结束时 bridge「重启」

  const second = make(); // 同一 journal 重建
  assert.notEqual(done, undefined);
  assert.equal(second.isStaleCompletion(done!.event), true);
});

test("事故回放:完成事件积压期间新任务开跑,订阅分页跳过它", () => {
  const store = new NotificationEventStore({ baseDir: tmpDir() });
  store.load();
  let clock = Date.parse("2026-08-02T12:17:16.000Z");
  const detector = new NotificationDetector({
    bridgeInstallationId: BRIDGE_ID,
    eventEpoch: EPOCH,
    store,
    now: () => clock,
  });
  const manager = new NotificationSubscriptionManager(
    store,
    BRIDGE_ID,
    EPOCH,
    () => clock,
    (event) => detector.isStaleCompletion(event),
  );

  // 任务完成 → 事件落盘(手机断链,收不到)。
  detector.onTaskStart("source-a");
  clock += 39_000;
  const done = detector.onTaskEnd("source-a");
  assert.notEqual(done, undefined);
  // 新任务开跑,手机此刻才重连订阅。
  clock += 47_000;
  detector.onTaskStart("source-a");

  const request = parseSubscribeRequest({
    id: "sub-1",
    installationId: "inst-1",
    cursor: null,
    scopeVersion: 1,
  });
  assert.notEqual(request, undefined);
  const page = manager.subscribe(request!);
  assert.equal(page.type, "notification_events");
  const eventsPage = page as NotificationEventsPage;
  assert.deepEqual(eventsPage.events, []);
  assert.deepEqual(eventsPage.skippedRanges, [{ from: 1, through: 1 }]);
});
