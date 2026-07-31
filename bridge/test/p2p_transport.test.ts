import assert from "node:assert/strict";
import test from "node:test";
import {
  CreditController,
  P2P_CONTROL_FRAME_MAX_BYTES,
  P2P_CREDIT_MAX_BYTES,
  P2P_CREDIT_MIN_BYTES,
  P2P_INTERACTIVE_FRAME_MAX_BYTES,
  classifyFrame,
  topLevelType,
} from "../src/p2p_transport.js";

test("classifyFrame: ping/pong/ack 归 control", () => {
  assert.equal(classifyFrame(JSON.stringify({ type: "bridge_ping" })), "control");
  assert.equal(classifyFrame(JSON.stringify({ type: "bridge_pong", echo: 1 })), "control");
  assert.equal(classifyFrame(JSON.stringify({ type: "transfer_ack", id: "x" })), "control");
});

test("classifyFrame: 小 response 归 interactive,大 response 归 bulk", () => {
  const small = JSON.stringify({ type: "response", id: "r1", success: true, data: {} });
  assert.ok(small.length <= P2P_INTERACTIVE_FRAME_MAX_BYTES);
  assert.equal(classifyFrame(small), "interactive");

  const big = JSON.stringify({
    type: "response",
    id: "r2",
    success: true,
    data: { blob: "x".repeat(P2P_INTERACTIVE_FRAME_MAX_BYTES) },
  });
  assert.ok(big.length > P2P_INTERACTIVE_FRAME_MAX_BYTES);
  assert.equal(classifyFrame(big), "bulk", "大响应永远不许进交互队列");
});

test("classifyFrame: 小广播归 interactive,流式事件与未知帧归 bulk", () => {
  assert.equal(classifyFrame(JSON.stringify({ type: "hub_sessions_changed" })), "interactive");
  assert.equal(classifyFrame(JSON.stringify({ type: "hub_sources_changed" })), "interactive");
  assert.equal(classifyFrame(JSON.stringify({ type: "hub_ask_started", requestId: "a" })), "interactive");
  assert.equal(classifyFrame(JSON.stringify({ type: "message_update", message: {} })), "bulk");
  assert.equal(classifyFrame("not even json"), "bulk");
});

test("CreditController: 初始信用有界,排空速率上升时信用放大", () => {
  const credit = new CreditController();
  const initial = credit.target;
  assert.ok(initial >= P2P_CREDIT_MIN_BYTES && initial <= P2P_CREDIT_MAX_BYTES);

  // 模拟快链路:每 100ms 排空 500KB,速率 5MB/s,目标应涨到 ~2MB(硬顶)。
  let now = 1_000_000;
  credit.sample(2_000_000, now);
  for (let i = 0; i < 20; i++) {
    now += 100;
    credit.sample(1_500_000, now);
    now += 100;
    credit.sample(1_000_000, now);
  }
  assert.ok(
    credit.target > P2P_CREDIT_MAX_BYTES * 0.9 &&
      credit.target <= P2P_CREDIT_MAX_BYTES,
    `快链路信用应逼近硬顶,实际 ${credit.target}`,
  );

  // 模拟慢链路:每 100ms 只排空 100B,目标应收到底(单片 48KB)。
  const slow = new CreditController();
  let t = 1_000_000;
  slow.sample(500_000, t);
  for (let i = 0; i < 50; i++) {
    t += 100;
    slow.sample(500_000 - (i + 1) * 100, t);
  }
  assert.equal(slow.target, P2P_CREDIT_MIN_BYTES);
});

test("CreditController: 字节推进重置无进度计时", async () => {
  const credit = new CreditController();
  const before = credit.noProgressMs;
  await new Promise((resolve) => setTimeout(resolve, 30));
  credit.sample(1_000, Date.now());
  credit.sample(0, Date.now() + 100);
  assert.ok(credit.noProgressMs < before + 200, "有推进时 noProgress 不应持续增长");
});

test("CreditController: 慢链路的平坦采样后整片下降,不得被误判成高速链路", () => {
  const credit = new CreditController();
  let now = 5_000_000;

  // 50KB/s 的真实形态:36KB 压进缓冲后长时间不动,约 740ms 后整片落下。
  credit.sample(36 * 1024, now);
  for (let i = 0; i < 36; i++) {
    now += 20;
    credit.sample(36 * 1024, now); // 平坦采样:buffered 一动不动
  }
  now += 20;
  credit.sample(0, now); // 整片排空

  // 修复前:每次平坦采样都把测速窗口起点推到当前时刻,这一降被除以 ~20ms,
  // 算出约 1.8MB/s,信用目标涨到约 500KB —— 等于允许十几秒的 bulk 排在 pong
  // 前面,健康慢链路会被 10s 心跳判死并反复重连。
  assert.equal(
    credit.target,
    P2P_CREDIT_MIN_BYTES,
    `慢链路信用应贴住下限,实际 ${credit.target}`,
  );
});

test("CreditController: 长时间完全停滞时速率估计衰减", () => {
  const credit = new CreditController();
  let now = 6_000_000;

  // 先用快链路把估计值抬到硬顶。
  credit.sample(1_000_000, now);
  for (let i = 0; i < 10; i++) {
    now += 100;
    credit.sample(500_000, now);
    now += 100;
    credit.sample(1_000_000, now);
  }
  const fast = credit.target;
  assert.ok(fast > P2P_CREDIT_MIN_BYTES, "快链路信用应高于下限");

  // 链路停死:缓冲一直不动,估计值必须衰减回保守窗口。
  for (let i = 0; i < 20; i++) {
    now += 1_100;
    credit.sample(1_000_000, now);
  }

  assert.equal(credit.target, P2P_CREDIT_MIN_BYTES, "停滞后信用应收回下限");
});

test("CreditController: 缓冲变大不算负排空", () => {
  const credit = new CreditController();
  let now = 7_000_000;
  const initial = credit.target;

  credit.sample(0, now);
  now += 100;
  credit.sample(500_000, now); // 压入新帧
  now += 100;
  credit.sample(500_000, now);

  // 没有任何真实排空,信用目标不应因负数计算而变化。
  assert.equal(credit.target, initial);
});

test("classifyFrame: 内嵌 bridge_ping 的普通响应不得被判成 control", () => {
  // 已复现过的缺陷:子串匹配看到 payload 文本里的 {"type":"bridge_ping"}
  // 就把一条 10KB 普通响应判成 control,直接插到控制队列最前面 ——
  // 普通载荷能冒充控制帧,优先级与预算分类就都失效了。
  const nested = JSON.stringify({
    type: "response",
    command: "get_entries",
    data: "x".repeat(10_000) + '{"type":"bridge_ping"}',
  });
  assert.equal(topLevelType(nested), "response", "顶层 type 必须是 response");
  assert.equal(
    classifyFrame(nested),
    "bulk",
    "大响应必须归 bulk,不能因为内嵌文本被提成 control",
  );
});

test("classifyFrame: 超大伪控制帧降级为 bulk", () => {
  // 控制帧本就只有几十到几百字节。构造一个 5KB 的 "bridge_ping" 来插队,
  // 必须被硬上限拦下 —— 否则控制队列可以被撑爆。
  const fat = JSON.stringify({ type: "bridge_ping", pad: "y".repeat(5_000) });
  assert.ok(
    Buffer.byteLength(fat) > P2P_CONTROL_FRAME_MAX_BYTES,
    "构造帧应超过控制帧硬上限",
  );
  assert.equal(classifyFrame(fat), "bulk");

  // 真控制帧不受影响。
  assert.equal(classifyFrame(JSON.stringify({ type: "bridge_ping", echo: "a" })), "control");
  assert.equal(classifyFrame(JSON.stringify({ type: "transfer_ack", id: "x" })), "control");
});

test("classifyFrame: 阈值按 UTF-8 字节而不是 UTF-16 字符", () => {
  // CJK 一字 3 字节。3000 字符的响应只有 3029 个 UTF-16 单元,
  // 但有 9029 字节 —— 按字符判定会让 8KB 阈值实际放行到约 24KB。
  const cjk = JSON.stringify({ type: "response", data: "中".repeat(3_000) });
  assert.ok(cjk.length < P2P_INTERACTIVE_FRAME_MAX_BYTES, "UTF-16 长度应小于阈值");
  assert.ok(
    Buffer.byteLength(cjk) > P2P_INTERACTIVE_FRAME_MAX_BYTES,
    "UTF-8 字节应大于阈值",
  );
  assert.equal(classifyFrame(cjk), "bulk", "必须按字节判定");
});

test("topLevelType: 只认深度 1 的 type,异常输入不炸", () => {
  // 嵌套对象里的 type 不算。
  assert.equal(
    topLevelType(JSON.stringify({ command: "x", inner: { type: "bridge_ping" } })),
    undefined,
  );
  // 顶层不是对象。
  assert.equal(topLevelType("[1,2,3]"), undefined);
  assert.equal(topLevelType("null"), undefined);
  assert.equal(topLevelType(""), undefined);
  // type 不是字符串。
  assert.equal(topLevelType(JSON.stringify({ type: 42 })), undefined);
  // 转义内容不能骗过键匹配。
  assert.equal(
    topLevelType(JSON.stringify({ ty: 'pe":"bridge_ping', type: "response" })),
    "response",
  );
  // 未闭合 JSON 不得抛异常。
  assert.equal(topLevelType('{"type":"bridge_ping'), "bridge_ping");
  assert.doesNotThrow(() => classifyFrame('{"broken'));
});

test("CreditController: 空闲期(缓冲为0)不得衰减速率估计", () => {
  const credit = new CreditController();
  let now = 9_000_000;

  // 先用真实排空把估计值抬起来。
  credit.sample(200 * 1024, now);
  for (let i = 0; i < 6; i++) {
    now += 100;
    credit.sample(200 * 1024 - (i + 1) * 20 * 1024, now);
  }
  const warm = credit.target;
  assert.ok(warm > P2P_CREDIT_MIN_BYTES, `热态信用应高于下限,实际 ${warm}`);

  // 空闲:缓冲一直是 0(没有任何东西要发)。真机实测过后果 —— 每 15s 一次
  // 心跳都会让估计值对折,几分钟后 drainBps 从 128KB/s 掉到 4KB/s 地板,
  // 空闲之后的第一批数据于是从最保守的信用窗口起步。
  for (let i = 0; i < 20; i++) {
    now += 15_000;
    credit.sample(0, now);
  }

  assert.equal(
    credit.target,
    warm,
    "缓冲为 0 说明没有东西要排空,不是链路慢的证据,不得衰减",
  );
});

test("CreditController: 真停滞(缓冲不为0且不下降)仍要衰减", () => {
  const credit = new CreditController();
  let now = 9_500_000;

  credit.sample(300 * 1024, now);
  for (let i = 0; i < 6; i++) {
    now += 100;
    credit.sample(300 * 1024 - (i + 1) * 30 * 1024, now);
  }
  const warm = credit.target;
  assert.ok(warm > P2P_CREDIT_MIN_BYTES);

  // 缓冲卡住不动:这是真停滞,必须衰减。
  for (let i = 0; i < 20; i++) {
    now += 1_100;
    credit.sample(120 * 1024, now);
  }

  assert.ok(
    credit.target < warm,
    `真停滞必须衰减(warm=${warm} now=${credit.target})`,
  );
});
