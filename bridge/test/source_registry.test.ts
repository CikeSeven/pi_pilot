import assert from "node:assert/strict";
import test from "node:test";
import { SourceRegistry } from "../src/source_registry.js";

const transport = { send: () => true };

function createRegistry(capacity = 2) {
  const registry = new SourceRegistry(capacity);
  registry.register(
    {
      id: "desktop:one",
      kind: "desktop",
      label: "Desktop one",
      connected: true,
      epoch: "epoch-1",
      capabilities: ["prompt", "abort"],
    },
    transport,
  );
  registry.setSnapshot("desktop:one", {
    epoch: "epoch-1",
    baseSeq: 0,
    capturedAt: 1,
    state: { sessionId: "session-1", cwd: "/tmp/project" },
    entries: [],
    leafId: null,
  });
  return registry;
}

test("desktop event sequence is strict", () => {
  const registry = createRegistry();
  assert.equal(registry.recordDesktopEvent("desktop:one", "epoch-1", 1, { type: "turn_start" }).ok, true);
  const gap = registry.recordDesktopEvent("desktop:one", "epoch-1", 3, { type: "turn_end" });
  assert.deepEqual(gap, { ok: false, error: "sequence_gap" });
  const stale = registry.recordDesktopEvent("desktop:one", "old", 2, { type: "turn_end" });
  assert.deepEqual(stale, { ok: false, error: "stale_epoch" });
});

test("matching cursors replay retained events", () => {
  const registry = createRegistry();
  registry.recordDesktopEvent("desktop:one", "epoch-1", 1, { type: "turn_start" });
  registry.recordDesktopEvent("desktop:one", "epoch-1", 2, { type: "turn_end" });

  const sync = registry.sync("desktop:one", {
    hubId: registry.hubId,
    sourceId: "desktop:one",
    sourceEpoch: "epoch-1",
    seq: 1,
  });
  assert.equal(sync?.mode, "replay");
  assert.deepEqual(sync?.events.map((event) => event.seq), [2]);
});

test("cursor outside the ring falls back to snapshot plus retained events", () => {
  const registry = createRegistry(2);
  registry.recordDesktopEvent("desktop:one", "epoch-1", 1, { type: "message_start" });
  registry.recordDesktopEvent("desktop:one", "epoch-1", 2, { type: "message_update" });
  registry.recordDesktopEvent("desktop:one", "epoch-1", 3, { type: "message_end" });

  const sync = registry.sync("desktop:one", {
    hubId: registry.hubId,
    sourceId: "desktop:one",
    sourceEpoch: "epoch-1",
    seq: 0,
  });
  assert.equal(sync?.mode, "snapshot");
  assert.deepEqual(sync?.events.map((event) => event.seq), [2, 3]);
});

test("headless RPC sync exposes its current sequence barrier", () => {
  const registry = new SourceRegistry(2);
  registry.register(
    {
      id: "headless:local",
      kind: "headless",
      label: "Headless",
      connected: true,
      epoch: "headless-1",
      capabilities: ["pi-rpc"],
    },
    transport,
  );
  registry.recordLocalEvent("headless:local", { type: "agent_start" });
  registry.recordLocalEvent("headless:local", { type: "agent_end" });
  const sync = registry.sync("headless:local");
  assert.equal(sync?.mode, "rpc");
  if (sync?.mode === "rpc") assert.equal(sync.baseSeq, 2);
});

test("source leases are isolated and released on disconnect", () => {
  const registry = createRegistry();
  registry.register(
    {
      id: "headless:local",
      kind: "headless",
      label: "Headless",
      connected: true,
      epoch: "headless-1",
      capabilities: ["pi-rpc"],
    },
    transport,
  );

  assert.equal(registry.acquire("desktop:one", "phone-a", 5_000)?.ok, true);
  assert.equal(registry.acquire("headless:local", "phone-b", 5_000)?.ok, true);
  assert.deepEqual(registry.releaseClient("phone-a"), ["desktop:one"]);
  assert.equal(registry.list("phone-b").find((source) => source.id === "headless:local")?.ownedByYou, true);
});
