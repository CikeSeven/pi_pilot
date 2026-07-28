import assert from "node:assert/strict";
import test from "node:test";
import { executeRemoteCommand, type CommandRuntime } from "../src/remote_commands.js";

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

// 以前这里抛错,消息直接丢掉。压缩上下文期间 isIdle() 为 false 而客户端
// 看到的 isStreaming 是 false,双方对「忙」的判断必然错开 —— 兜底排队而不是丢。
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
