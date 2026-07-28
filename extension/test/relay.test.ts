import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DesktopRelay } from "../src/relay.js";

type Frame = Record<string, any>;

async function waitFor<T>(read: () => T | undefined, timeoutMs = 2_000): Promise<T> {
  const started = Date.now();
  for (;;) {
    const value = read();
    if (value !== undefined) return value;
    if (Date.now() - started > timeoutMs) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("relay registers, coalesces updates, and fences commands", async () => {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");
  const address = server.address();
  assert.notEqual(typeof address, "string");
  assert.ok(address && typeof address !== "string");

  const frames: Frame[] = [];
  let sourceSocket: WebSocket | undefined;
  server.on("connection", (socket) => {
    sourceSocket = socket;
    socket.send(JSON.stringify({ type: "desktop_hello", version: 2, hubId: "test-hub" }));
    socket.on("message", (data) => {
      const frame = JSON.parse(data.toString()) as Frame;
      frames.push(frame);
      if (frame.type === "desktop_register") {
        socket.send(
          JSON.stringify({
            type: "desktop_registered",
            hubId: "test-hub",
            sourceId: frame.source.sourceId,
            epoch: frame.snapshot.epoch,
          }),
        );
      }
    });
  });

  const sentMessages: Array<{ message: string; options?: unknown }> = [];
  let blockModel = false;
  let resolveModel: (() => void) | undefined;
  let markModelStarted: (() => void) | undefined;
  const modelStarted = new Promise<void>((resolve) => {
    markModelStarted = resolve;
  });
  const pi = {
    getThinkingLevel: () => "high",
    sendUserMessage(message: string, options?: unknown) {
      sentMessages.push({ message, options });
    },
    async setModel() {
      if (blockModel) {
        markModelStarted?.();
        await new Promise<void>((resolve) => {
          resolveModel = resolve;
        });
      }
      return true;
    },
    setThinkingLevel: () => {},
  } as unknown as ExtensionAPI;
  const statuses: Array<string | undefined> = [];
  const ctx = {
    mode: "tui",
    cwd: "/tmp/pipilot-relay-test",
    model: undefined,
    ui: {
      setStatus(_key: string, value: string | undefined) {
        statuses.push(value);
      },
    },
    sessionManager: {
      getBranch: () => [
        {
          type: "message",
          id: "entry-1",
          parentId: null,
          timestamp: 1,
          message: { role: "user", content: "existing", timestamp: 1 },
        },
      ],
      getTree: () => [
        {
          entry: {
            type: "message",
            id: "entry-1",
            parentId: null,
            timestamp: 1,
            message: { role: "user", content: "existing", timestamp: 1 },
          },
          children: [],
        },
      ],
      getSessionId: () => "in-memory-session",
      getSessionFile: () => undefined,
      getSessionName: () => "Test",
      getLeafId: () => "entry-1",
    },
    modelRegistry: {
      getAvailable: () => [],
      find: (provider: string, modelId: string) => ({
        provider,
        id: modelId,
        name: "Test model",
      }),
    },
    getContextUsage: () => undefined,
    isIdle: () => true,
    hasPendingMessages: () => false,
    abort: () => {},
  } as unknown as ExtensionContext;

  const relay = new DesktopRelay(pi, {
    url: `ws://127.0.0.1:${address.port}/desktop?token=test`,
    token: "test",
    reconnectMinMs: 20,
    reconnectMaxMs: 100,
    streamSnapshotEvents: 192,
    streamSnapshotMaxMs: 15_000,
    askClaimMs: 8_000,
    askAnswerMs: 300_000,
  });

  try {
    relay.start(ctx);
    const registration = await waitFor(() =>
      frames.find((frame) => frame.type === "desktop_register"),
    );
    assert.equal(registration.snapshot.entries[0].id, "entry-1");
    await waitFor(() => frames.find((frame) => frame.type === "desktop_snapshot"));

    // 会话树走独立按需帧,不依赖快照里的可选 treeSummary 字段。
    sourceSocket!.send(
      JSON.stringify({
        type: "desktop_tree_request",
        requestId: "tree-1",
        epoch: registration.snapshot.epoch,
      }),
    );
    const tree = await waitFor(() =>
      frames.find((frame) => frame.type === "desktop_tree" && frame.requestId === "tree-1"),
    );
    assert.equal(tree.epoch, registration.snapshot.epoch);
    assert.equal(tree.leafId, "entry-1");
    assert.equal(tree.tree[0].id, "entry-1");

    relay.emitMessageUpdate(
      { type: "message_update", message: { role: "assistant", content: "a" } },
      ctx,
    );
    relay.emitMessageUpdate(
      { type: "message_update", message: { role: "assistant", content: "ab" } },
      ctx,
    );
    await waitFor(() =>
      frames.find(
        (frame) => frame.type === "desktop_event" && frame.event?.type === "message_update",
      ),
    );
    const updates = frames.filter(
      (frame) => frame.type === "desktop_event" && frame.event?.type === "message_update",
    );
    assert.equal(updates.length, 1);
    assert.equal(updates[0]!.event.message.content, "ab");

    // pi 的 ExtensionRunner 每次 emit 都 createContext() 新建一个 ctx 对象。
    // relay 曾经用 `this.ctx === ctx` 判定,于是 session_start 之后的**每一个**
    // 事件都被静默丢掉 —— 桌面源看起来在线,内容却永远不更新。
    const freshCtx = Object.create(
      Object.getPrototypeOf(ctx) as object,
      Object.getOwnPropertyDescriptors(ctx),
    ) as ExtensionContext;
    assert.notEqual(freshCtx, ctx);
    relay.emitEvent({ type: "user_bash", command: "ls" }, freshCtx);
    await waitFor(() =>
      frames.find(
        (frame) => frame.type === "desktop_event" && frame.event?.type === "user_bash",
      ),
    );

    assert.ok(sourceSocket);
    sourceSocket!.send(
      JSON.stringify({
        type: "desktop_status",
        selectedClients: 1,
        owner: { owned: true, fence: 5, expiresAt: Date.now() + 5_000 },
      }),
    );
    await waitFor(() => statuses.find((status) => status === "PiPilot: controlled (1)"));
    sourceSocket!.send(
      JSON.stringify({
        type: "remote_command",
        requestId: "request-1",
        epoch: registration.snapshot.epoch,
        fence: 5,
        command: { type: "prompt", message: "from phone" },
      }),
    );
    const accepted = await waitFor(() =>
      frames.find((frame) => frame.type === "remote_result" && frame.requestId === "request-1"),
    );
    assert.equal(accepted.success, true);
    assert.deepEqual(sentMessages, [{ message: "from phone", options: undefined }]);

    sourceSocket!.send(
      JSON.stringify({
        type: "remote_command",
        requestId: "request-2",
        epoch: registration.snapshot.epoch,
        fence: 4,
        command: { type: "prompt", message: "stale" },
      }),
    );
    const stale = await waitFor(() =>
      frames.find((frame) => frame.type === "remote_result" && frame.requestId === "request-2"),
    );
    assert.equal(stale.success, false);
    assert.match(stale.error, /stale fencing token/);

    blockModel = true;
    sourceSocket!.send(
      JSON.stringify({
        type: "desktop_status",
        selectedClients: 1,
        owner: { owned: true, fence: 6, expiresAt: Date.now() + 5_000 },
      }),
    );
    sourceSocket!.send(
      JSON.stringify({
        type: "remote_command",
        requestId: "request-slow",
        epoch: registration.snapshot.epoch,
        fence: 6,
        command: { type: "set_model", provider: "test", modelId: "slow" },
      }),
    );
    await modelStarted;
    sourceSocket!.send(
      JSON.stringify({
        type: "remote_command",
        requestId: "request-queued",
        epoch: registration.snapshot.epoch,
        fence: 6,
        command: { type: "prompt", message: "must not run" },
      }),
    );
    sourceSocket!.send(
      JSON.stringify({
        type: "desktop_status",
        selectedClients: 1,
        owner: { owned: false, fence: null, expiresAt: null },
      }),
    );
    sourceSocket!.send(
      JSON.stringify({
        type: "desktop_status",
        selectedClients: 1,
        owner: { owned: true, fence: 7, expiresAt: Date.now() + 5_000 },
      }),
    );
    await waitFor(() => statuses.find((status) => status === "PiPilot: synced (1)"));
    resolveModel?.();
    const slow = await waitFor(() =>
      frames.find(
        (frame) => frame.type === "remote_result" && frame.requestId === "request-slow",
      ),
    );
    const queued = await waitFor(() =>
      frames.find(
        (frame) => frame.type === "remote_result" && frame.requestId === "request-queued",
      ),
    );
    assert.equal(slow.success, true);
    assert.equal(queued.success, false);
    assert.match(queued.error, /stale owner lease/);

    resolveModel = undefined;
    sourceSocket!.send(
      JSON.stringify({
        type: "desktop_status",
        selectedClients: 1,
        owner: { owned: true, fence: 8, expiresAt: Date.now() + 200 },
      }),
    );
    sourceSocket!.send(
      JSON.stringify({
        type: "remote_command",
        requestId: "request-expiry-slow",
        epoch: registration.snapshot.epoch,
        fence: 8,
        command: { type: "set_model", provider: "test", modelId: "expiry-slow" },
      }),
    );
    const releaseExpirySlow = await waitFor(() => resolveModel);
    sourceSocket!.send(
      JSON.stringify({
        type: "remote_command",
        requestId: "request-expired",
        epoch: registration.snapshot.epoch,
        fence: 8,
        command: { type: "prompt", message: "expired lease must not run" },
      }),
    );
    await new Promise((resolve) => setTimeout(resolve, 250));
    releaseExpirySlow();
    const expirySlow = await waitFor(() =>
      frames.find(
        (frame) =>
          frame.type === "remote_result" && frame.requestId === "request-expiry-slow",
      ),
    );
    const expired = await waitFor(() =>
      frames.find(
        (frame) => frame.type === "remote_result" && frame.requestId === "request-expired",
      ),
    );
    assert.equal(expirySlow.success, true);
    assert.equal(expired.success, false);
    assert.match(expired.error, /stale owner lease/);
    assert.deepEqual(sentMessages, [{ message: "from phone", options: undefined }]);
    assert.equal(statuses.includes("PiPilot: synced"), true);
  } finally {
    relay.stop(ctx);
    for (const socket of server.clients) socket.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("on-demand snapshot keeps the epoch and lands exactly on the last event", async () => {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");

  const frames: Frame[] = [];
  let sourceSocket: WebSocket | undefined;
  server.on("connection", (socket) => {
    sourceSocket = socket;
    socket.send(JSON.stringify({ type: "desktop_hello", version: 3, hubId: "test-hub" }));
    socket.on("message", (data) => {
      const frame = JSON.parse(data.toString()) as Frame;
      frames.push(frame);
      if (frame.type === "desktop_register") {
        socket.send(
          JSON.stringify({
            type: "desktop_registered",
            hubId: "test-hub",
            sourceId: frame.source.sourceId,
            epoch: frame.snapshot.epoch,
          }),
        );
      }
    });
  });

  const pi = {
    getThinkingLevel: () => "low",
    getCommands: () => [],
    setSessionName: () => {},
  } as unknown as ExtensionAPI;

  const ctx = {
    cwd: "/tmp/project",
    model: { id: "m", name: "M", provider: "p" },
    sessionManager: {
      getBranch: () => [],
      getEntries: () => [],
      getTree: () => [],
      getSessionFile: () => "/tmp/project/session.jsonl",
      getSessionId: () => "session-1",
      getSessionName: () => "Session",
      getLeafId: () => null,
    },
    modelRegistry: { getAvailable: () => [], find: () => undefined },
    getContextUsage: () => undefined,
    isIdle: () => false,
    hasPendingMessages: () => false,
    abort: () => {},
  } as unknown as ExtensionContext;

  const relay = new DesktopRelay(pi, {
    url: `ws://127.0.0.1:${address.port}/desktop?token=test`,
    token: "test",
    reconnectMinMs: 20,
    reconnectMaxMs: 100,
    streamSnapshotEvents: 192,
    streamSnapshotMaxMs: 15_000,
    askClaimMs: 8_000,
    askAnswerMs: 300_000,
  });

  try {
    relay.start(ctx);
    const registration = await waitFor(() =>
      frames.find((frame) => frame.type === "desktop_register"),
    );
    const epoch = registration.snapshot.epoch as string;
    await waitFor(() => (sourceSocket ? true : undefined));

    // 推几个事件把 seq 抬起来
    relay.emitBoundary({ type: "turn_start" }, ctx);
    relay.emitBoundary({ type: "message_start" }, ctx);
    const lastEvent = await waitFor(() => {
      const events = frames.filter((frame) => frame.type === "desktop_event");
      return events.length >= 2 ? events[events.length - 1] : undefined;
    });

    // hub 索要一份新快照
    sourceSocket!.send(
      JSON.stringify({ type: "desktop_snapshot_request", requestId: "r1", epoch }),
    );
    const snapshot = await waitFor(() =>
      frames.find((frame) => frame.type === "desktop_snapshot" && frame.requestId === "r1"),
    );

    // 关键三条:回传 requestId、epoch 不变(否则会清空 hub 的重放环并毁掉租约)、
    // baseSeq 正好等于线上最后一个事件(先 flush 后 capture 的结果)
    assert.equal(snapshot.requestId, "r1");
    assert.equal(snapshot.snapshot.epoch, epoch);
    assert.equal(snapshot.snapshot.baseSeq, lastEvent.seq);
    // 快照里必须带上"正在生成"(ctx.isIdle() === false)
    assert.equal(snapshot.snapshot.state.isStreaming, true);

    // 后续事件必须接着 baseSeq+1
    relay.emitBoundary({ type: "turn_end" }, ctx);
    const next = await waitFor(() =>
      frames.find(
        (frame) => frame.type === "desktop_event" && frame.seq === snapshot.snapshot.baseSeq + 1,
      ),
    );
    assert.equal(next.epoch, epoch);
  } finally {
    relay.stop(ctx);
    for (const socket of server.clients) socket.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
