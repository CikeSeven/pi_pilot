import assert from "node:assert/strict";
import test from "node:test";
import { quiesceSourceForHandoff } from "../src/source_handoff.js";

test("handoff blocks writes before awaiting the old owner stop", async () => {
  const order: string[] = [];
  let releaseStop: (() => void) | undefined;
  const stopGate = new Promise<void>((resolve) => {
    releaseStop = resolve;
  });

  const handoff = quiesceSourceForHandoff({
    isConnected: () => true,
    blockNewCommands: () => order.push("blocked"),
    failPending: () => order.push("pending-failed"),
    notifyOffline: () => order.push("offline-notified"),
    stopOwner: async () => {
      order.push("stop-started");
      await stopGate;
      order.push("stop-finished");
    },
  }).then(() => order.push("replacement-may-register"));

  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(order, ["blocked", "pending-failed", "offline-notified", "stop-started"]);
  releaseStop?.();
  await handoff;
  assert.deepEqual(order, [
    "blocked",
    "pending-failed",
    "offline-notified",
    "stop-started",
    "stop-finished",
    "replacement-may-register",
  ]);
});
