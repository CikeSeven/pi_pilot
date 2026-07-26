import assert from "node:assert/strict";
import test from "node:test";
import { buildPiArgs, buildPiArgsForSessionPath } from "../src/config.js";

const opts = {
  provider: "provider",
  model: "model",
  thinking: "high",
  sessionName: "PiPilot",
};

test("pinned headless startup uses an exact project session id", () => {
  const args = buildPiArgs("session-id", opts);
  assert.deepEqual(args.slice(0, 4), ["--mode", "rpc", "--session-id", "session-id"]);
  assert.equal(args.includes("--session"), false);
});

test("explicit session switching starts directly from the validated path", () => {
  const args = buildPiArgsForSessionPath("/tmp/session.jsonl", opts);
  assert.deepEqual(args.slice(0, 4), ["--mode", "rpc", "--session", "/tmp/session.jsonl"]);
  assert.equal(args.includes("--session-id"), false);
  assert.deepEqual(args.slice(-6), [
    "--provider",
    "provider",
    "--model",
    "model",
    "--thinking",
    "high",
  ]);
});
