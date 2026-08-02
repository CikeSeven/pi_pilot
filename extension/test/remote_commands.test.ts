import assert from "node:assert/strict";
import test from "node:test";
import {
  abortRemoteOperation,
  executeRemoteCommand,
  type CommandRuntime,
} from "../src/remote_commands.js";

function runtime(idle: boolean, modelResult = true) {
  const calls: Array<{ name: string; value?: unknown }> = [];
  let thinking = "low";
  const value = {
    pi: {
      sendUserMessage(message: string, options?: unknown) {
        calls.push({ name: "message", value: { message, options } });
      },
      async setModel(model: unknown) {
        calls.push({ name: "model", value: model });
        return modelResult;
      },
      getThinkingLevel() {
        return thinking;
      },
      setThinkingLevel(level: string) {
        thinking = level;
        calls.push({ name: "thinking", value: level });
      },
    },
    ctx: {
      abort() {
        calls.push({ name: "abort" });
      },
      isIdle: () => idle,
      modelRegistry: {
        find(provider: string, modelId: string) {
          return provider === "provider" && modelId === "model"
            ? { provider, id: modelId, name: "Model" }
            : undefined;
        },
      },
    },
  } as unknown as CommandRuntime;
  return { value, calls };
}

test("idle prompt starts immediately", async () => {
  const { value, calls } = runtime(true);
  const result = await executeRemoteCommand({ type: "prompt", message: "hello" }, value);
  assert.deepEqual(result, { accepted: true, delivery: "immediate" });
  assert.deepEqual(calls[0], { name: "message", value: { message: "hello", options: undefined } });
});

// 普通生成期间客户端漏传投递模式时,仍用 followUp 兜底避免消息丢失。
test("busy prompt without delivery mode falls back to followUp", async () => {
  const { value, calls } = runtime(false);
  const result = await executeRemoteCommand({ type: "prompt", message: "hello" }, value);
  assert.deepEqual(result, { accepted: true, delivery: "followUp" });
  assert.deepEqual(calls[0], {
    name: "message",
    value: { message: "hello", options: { deliverAs: "followUp" } },
  });
});

test("busy prompt ignores an unknown delivery mode instead of dropping", async () => {
  const { value, calls } = runtime(false);
  const result = await executeRemoteCommand(
    { type: "prompt", message: "hello", streamingBehavior: "bogus" },
    value,
  );
  assert.deepEqual(result, { accepted: true, delivery: "followUp" });
  assert.deepEqual(calls[0], {
    name: "message",
    value: { message: "hello", options: { deliverAs: "followUp" } },
  });
});

test("busy prompt forwards steer exactly", async () => {
  const { value, calls } = runtime(false);
  await executeRemoteCommand(
    { type: "prompt", message: "correct this", streamingBehavior: "steer" },
    value,
  );
  assert.deepEqual(calls[0], {
    name: "message",
    value: { message: "correct this", options: { deliverAs: "steer" } },
  });
});

test("compacting prompt is rejected instead of pretending followUp will queue it", async () => {
  const { value, calls } = runtime(true);
  value.ctx.isCompacting = () => true;

  await assert.rejects(
    executeRemoteCommand(
      { type: "prompt", message: "after compaction", streamingBehavior: "followUp" },
      value,
    ),
    /compacting; abort first/,
  );
  assert.equal(calls.some((call) => call.name === "message"), false);
});

test("abort stops generation and compaction, then waits for both to settle", async () => {
  const calls: string[] = [];
  let idle = false;
  let compacting = true;
  const result = await abortRemoteOperation(
    {
      abort() {
        calls.push("abort");
        setTimeout(() => {
          idle = true;
        }, 5);
      },
      abortCompaction() {
        calls.push("abortCompaction");
        setTimeout(() => {
          compacting = false;
        }, 10);
      },
      isIdle: () => idle,
      isCompacting: () => compacting,
    },
    { timeoutMs: 200 },
  );

  assert.deepEqual(calls, ["abort", "abortCompaction"]);
  assert.deepEqual(result, { compaction: true });
  assert.equal(idle, true);
  assert.equal(compacting, false);
});

test("compaction abort fails explicitly when the host capability is unavailable", async () => {
  let aborted = false;
  await assert.rejects(
    abortRemoteOperation(
      {
        abort() {
          aborted = true;
        },
        isIdle: () => true,
        isCompacting: () => true,
      },
      { timeoutMs: 20 },
    ),
    /cannot abort compaction/,
  );
  assert.equal(aborted, false);
});

test("model and thinking controls are allowlisted", async () => {
  const { value, calls } = runtime(true);
  const model = await executeRemoteCommand(
    { type: "set_model", provider: "provider", modelId: "model" },
    value,
  );
  assert.equal((model as { id: string }).id, "model");
  const thinking = await executeRemoteCommand(
    { type: "set_thinking_level", level: "high" },
    value,
  );
  assert.equal(calls.some((call) => call.name === "model"), true);
  assert.deepEqual(thinking, { level: "high" });
});

test("unknown commands and unavailable credentials are rejected", async () => {
  const unavailable = runtime(true, false).value;
  await assert.rejects(
    executeRemoteCommand(
      { type: "set_model", provider: "provider", modelId: "model" },
      unavailable,
    ),
    /credentials/,
  );
  await assert.rejects(
    executeRemoteCommand({ type: "switch_session" }, runtime(true).value),
    /unsupported desktop command/,
  );
});

test("set_session_name renames via pi API", async () => {
  const { value, calls } = runtime(true);
  (value.pi as any).setSessionName = (name: string) => {
    calls.push({ name: "rename", value: name });
  };
  const result = await executeRemoteCommand(
    { type: "set_session_name", name: "  新名字  " },
    value,
  );
  assert.deepEqual(result, { name: "新名字" });
  assert.deepEqual(calls.at(-1), { name: "rename", value: "新名字" });
});

test("set_session_name rejects empty and oversized names", async () => {
  const { value } = runtime(true);
  (value.pi as any).setSessionName = () => {};
  await assert.rejects(
    executeRemoteCommand({ type: "set_session_name", name: "   " }, value),
    /non-empty/,
  );
  await assert.rejects(
    executeRemoteCommand({ type: "set_session_name", name: "x".repeat(300) }, value),
    /too long/,
  );
});

// pi 确实把 compact 挂在 ExtensionContext 上(types.d.ts:240),
// 以前「not available on the desktop relay」是误判。
function compactRuntime(idle: boolean) {
  const calls: Array<{ name: string; value?: unknown }> = [];
  const value = {
    pi: {
      sendUserMessage() {},
      async setModel() {
        return false;
      },
      getThinkingLevel: () => "low",
      setThinkingLevel() {},
    },
    ctx: {
      abort() {},
      isIdle: () => idle,
      compact(options?: { customInstructions?: string; onError?: (e: Error) => void }) {
        calls.push({ name: "compact", value: options });
      },
      modelRegistry: { find: () => undefined },
    },
    onCompactError(message: string) {
      calls.push({ name: "compactError", value: message });
    },
  } as unknown as CommandRuntime;
  return { value, calls };
}

test("compact invokes ctx.compact without awaiting completion", async () => {
  const { value, calls } = compactRuntime(true);
  const result = await executeRemoteCommand({ type: "compact" }, value);
  // 只能报「已受理」:pi 的声明就是 trigger without awaiting。
  assert.deepEqual(result, { accepted: true });
  assert.equal(calls[0]?.name, "compact");
  assert.equal((calls[0]?.value as { customInstructions?: unknown }).customInstructions, undefined);
});

test("compact passes custom instructions through", async () => {
  const { value, calls } = compactRuntime(true);
  const result = await executeRemoteCommand(
    { type: "compact", instructions: " 保留报错 " },
    value,
  );
  assert.deepEqual(result, { accepted: true, instructions: "保留报错" });
  assert.equal(
    (calls[0]?.value as { customInstructions?: string }).customInstructions,
    "保留报错",
  );
});

test("compact is rejected while the desktop is busy", async () => {
  const { value, calls } = compactRuntime(false);
  await assert.rejects(
    () => executeRemoteCommand({ type: "compact" }, value),
    /busy/,
  );
  assert.equal(calls.length, 0, "忙的时候绝不能触发压缩");
});

test("compact errors reach the phone through onCompactError", async () => {
  const { value, calls } = compactRuntime(true);
  await executeRemoteCommand({ type: "compact" }, value);
  // ctx.compact() 不 await,失败只会走 onError 回调 ——
  // 不接的话手机会永远停在「正在压缩」。
  const options = calls[0]?.value as { onError?: (error: Error) => void };
  options.onError?.(new Error("boom"));
  assert.deepEqual(calls[1], { name: "compactError", value: "boom" });
});
