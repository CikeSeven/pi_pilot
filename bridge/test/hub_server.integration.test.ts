import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";
import { HUB_PROTOCOL_VERSION } from "../src/hub_protocol.js";

type Frame = Record<string, any>;

class Peer {
  private seq = 0;
  private readonly pending = new Map<string, (frame: Frame) => void>();
  readonly frames: Frame[] = [];

  constructor(readonly ws: WebSocket) {
    ws.on("message", (data) => {
      const frame = JSON.parse(data.toString()) as Frame;
      this.frames.push(frame);
      if (frame.type === "response" && typeof frame.id === "string") {
        this.pending.get(frame.id)?.(frame);
        this.pending.delete(frame.id);
      }
    });
  }

  request(type: string, extra: Frame = {}, id = `request-${++this.seq}`): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`request timed out: ${type}`));
      }, 3_000);
      this.pending.set(id, (frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
      this.ws.send(JSON.stringify({ type, id, ...extra }));
    });
  }

  async waitFor(predicate: (frame: Frame) => boolean, timeoutMs = 3_000): Promise<Frame> {
    const started = Date.now();
    for (;;) {
      const found = this.frames.find(predicate);
      if (found) return found;
      if (Date.now() - started > timeoutMs) throw new Error("frame timed out");
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
}

async function freePort(): Promise<number> {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const port = address.port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

async function open(url: string): Promise<Peer> {
  const ws = new WebSocket(url);
  const peer = new Peer(ws);
  await new Promise<void>((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  return peer;
}

async function waitForHealth(port: number, child: ChildProcess): Promise<void> {
  const started = Date.now();
  for (;;) {
    if (child.exitCode !== null) throw new Error(`hub exited early with ${child.exitCode}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {
      // Process is still binding the port.
    }
    if (Date.now() - started > 5_000) throw new Error("hub health check timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

test("Source Hub isolates clients and fences desktop mutations", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
    cwd: bridgeRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      PIPILOT_HOST: "127.0.0.1",
      PIPILOT_PORT: String(port),
      PIPILOT_TOKEN: "mobile-test-token",
      PIPILOT_DESKTOP_TOKEN: "desktop-test-token",
      PIPILOT_P2P_DEVICE_ID: "test-device",
      PIPILOT_HEADLESS_AUTO_START: "false",
      PI_CWD: bridgeRoot,
    },
  });

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const health = (await (
      await fetch(`http://127.0.0.1:${port}/health`)
    ).json()) as Record<string, unknown>;
    assert.equal(health.name, "test-device");
    const desktop = await open(
      `ws://127.0.0.1:${port}/desktop?token=desktop-test-token`,
    );
    peers.push(desktop);
    await desktop.waitFor((frame) => frame.type === "desktop_hello");
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:test",
          label: "Test desktop",
          cwd: "/tmp/pipilot-hub-test",
          sessionId: "session-test",
          capabilities: ["prompt", "abort", "set_model", "set_thinking_level"],
        },
        snapshot: {
          epoch: "epoch-test",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: {
            sessionId: "session-test",
            sessionName: "Test",
            cwd: "/tmp/pipilot-hub-test",
            isStreaming: false,
            model: { id: "model", name: "Model", provider: "provider" },
            thinkingLevel: "low",
          },
          entries: [],
          leafId: null,
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phoneA = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    const phoneB = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phoneA, phoneB);
    const hello = await phoneA.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(hello.version, HUB_PROTOCOL_VERSION);

    const unselected = await phoneA.request("get_state");
    assert.equal(unselected.success, false);
    assert.match(unselected.error, /select a source/);

    const listed = await phoneA.request("hub_list_sources");
    const headless = listed.data.sources.find(
      (source: Frame) => source.kind === "headless",
    );
    assert.equal(headless.connected, false);
    const offlineHeadless = await phoneA.request("hub_select_source", {
      sourceId: headless.id,
    });
    assert.equal(offlineHeadless.success, true);
    const offlineRead = await phoneA.request("get_state");
    assert.equal(offlineRead.success, false);
    assert.match(offlineRead.error, /offline/);

    assert.equal(
      (await phoneA.request("hub_select_source", { sourceId: "desktop:test" })).success,
      true,
    );
    assert.equal(
      (await phoneB.request("hub_select_source", { sourceId: "desktop:test" })).success,
      true,
    );
    const state = await phoneA.request("get_state");
    assert.equal(state.success, true);
    assert.equal(state.data.sessionId, "session-test");

    const denied = await phoneA.request("prompt", { message: "without lease" });
    assert.equal(denied.success, false);
    assert.match(denied.error, /owner lease/);

    const acquired = await phoneA.request("hub_acquire_owner", { ttlMs: 10_000 });
    assert.equal(acquired.success, true);
    // force:false 仍然尊重现有租约
    const contested = await phoneB.request("hub_acquire_owner", {
      ttlMs: 10_000,
      force: false,
    });
    assert.equal(contested.success, false);

    const lease = acquired.data;
    const promptPromise = phoneA.request(
      "prompt",
      {
        message: "from phone A",
        _hub: { leaseId: lease.leaseId, fence: lease.fence },
      },
      "same-client-id",
    );
    const remote = await desktop.waitFor(
      (frame) => frame.type === "remote_command" && frame.command?.message === "from phone A",
    );
    assert.notEqual(remote.requestId, "same-client-id");
    desktop.ws.send(
      JSON.stringify({
        type: "remote_result",
        requestId: remote.requestId,
        success: true,
        data: { accepted: true },
      }),
    );
    const promptResult = await promptPromise;
    assert.equal(promptResult.id, "same-client-id");
    assert.equal(promptResult.success, true);
    assert.equal(
      phoneB.frames.some((frame) => frame.type === "response" && frame.id === "same-client-id"),
      false,
    );

    desktop.ws.send(
      JSON.stringify({
        type: "desktop_event",
        epoch: "epoch-test",
        seq: 1,
        event: { type: "turn_start", turnIndex: 1, timestamp: 1 },
      }),
    );
    const eventA = await phoneA.waitFor((frame) => frame.type === "turn_start");
    const eventB = await phoneB.waitFor((frame) => frame.type === "turn_start");
    assert.equal(eventA._hub.seq, 1);
    assert.equal(eventB._hub.sourceId, "desktop:test");

    phoneA.ws.close();
    await new Promise((resolve) => setTimeout(resolve, 50));
    const acquiredAfterDisconnect = await phoneB.request("hub_acquire_owner", { ttlMs: 10_000 });
    assert.equal(acquiredAfterDisconnect.success, true);
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit; stderr: ${stderr}`)), 3_000),
      ),
    ]);
  }
});

function onceExit(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => child.once("exit", () => resolve()));
}
