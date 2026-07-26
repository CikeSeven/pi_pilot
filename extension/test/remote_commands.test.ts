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

test("busy prompt requires an explicit delivery mode", async () => {
  const { value } = runtime(false);
  await assert.rejects(
    executeRemoteCommand({ type: "prompt", message: "hello" }, value),
    /requires steer or followUp/,
  );
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
