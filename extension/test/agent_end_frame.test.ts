/**
 * index.ts 的 agentEndFrame:给扩展路径的 agent_end 补 willRetry/aborted
 * 结束方式标记。
 *
 * 背景:pi 给 session 订阅者的 agent_end 带 willRetry,但扩展事件只有
 * messages。没有这两个标记时,一次可重试的 API 报错会先弹「任务完成」
 * 再看到重试的 agent_start;用户中断(Esc/手机停止)也会被当成完成。
 */
import assert from "node:assert/strict";
import test from "node:test";
import { agentEndFrame } from "../src/index.js";

test("最后一个 assistant 是 error 时标记 willRetry", () => {
  const frame = agentEndFrame({
    type: "agent_end",
    messages: [
      { role: "user", content: [] },
      { role: "assistant", stopReason: "error", content: [] },
    ],
  }) as Record<string, unknown>;
  assert.equal(frame.willRetry, true);
  assert.equal(frame.aborted, undefined);
});

test("最后一个 assistant 是 aborted 时标记 aborted", () => {
  const frame = agentEndFrame({
    type: "agent_end",
    messages: [
      { role: "user", content: [] },
      { role: "assistant", stopReason: "aborted", content: [] },
    ],
  }) as Record<string, unknown>;
  assert.equal(frame.aborted, true);
  assert.equal(frame.willRetry, undefined);
});

test("正常结束的 agent_end 原样透传", () => {
  const event = {
    type: "agent_end",
    messages: [
      { role: "user", content: [] },
      { role: "assistant", stopReason: "stop", content: [] },
    ],
  };
  assert.equal(agentEndFrame(event), event);
});

test("只认最后一个 assistant:更早的 error 不算数", () => {
  const frame = agentEndFrame({
    type: "agent_end",
    messages: [
      { role: "assistant", stopReason: "error", content: [] },
      { role: "user", content: [] },
      { role: "assistant", stopReason: "stop", content: [] },
    ],
  }) as Record<string, unknown>;
  assert.equal(frame.willRetry, undefined);
  assert.equal(frame.aborted, undefined);
});

test("没有 messages 或没有 assistant 时原样透传", () => {
  const noMessages = { type: "agent_end" };
  assert.equal(agentEndFrame(noMessages), noMessages);
  const noAssistant = { type: "agent_end", messages: [{ role: "user" }] };
  assert.equal(agentEndFrame(noAssistant), noAssistant);
});

test("标记不改动原事件对象", () => {
  const event = {
    type: "agent_end",
    messages: [{ role: "assistant", stopReason: "aborted" }],
  };
  const frame = agentEndFrame(event) as Record<string, unknown>;
  assert.notEqual(frame, event);
  assert.equal((event as Record<string, unknown>).aborted, undefined);
  assert.equal(frame.aborted, true);
});
