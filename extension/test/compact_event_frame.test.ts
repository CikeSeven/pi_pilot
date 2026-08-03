import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DesktopRelay, compactEventFrame } from "../src/relay.js";

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

test("compactEventFrame 剥掉 branchEntries/preparation/signal,只留小字段", () => {
  const raw = {
    type: "session_before_compact",
    preparation: { messagesToSummarize: 10, tokensBefore: 120000 },
    branchEntries: [{ id: "e1" }, { id: "e2" }],
    customInstructions: undefined,
    reason: "overflow",
    willRetry: true,
    signal: new AbortController().signal,
  };
  assert.deepEqual(compactEventFrame(raw), {
    type: "session_before_compact",
    reason: "overflow",
    willRetry: true,
  });
});

test("compactEventFrame 从 compactionEntry 提取 tokensBefore 给完成统计", () => {
  const frame = compactEventFrame({
    type: "session_compact",
    compactionEntry: { type: "compaction", summary: "很长…", tokensBefore: 98765 },
    fromExtension: false,
    reason: "manual",
    willRetry: false,
  });
  assert.deepEqual(frame, {
    type: "session_compact",
    reason: "manual",
    willRetry: false,
    result: { tokensBefore: 98765 },
  });
  // 没有 tokensBefore 时不造空 result。
  assert.deepEqual(
    compactEventFrame({ type: "session_compact", compactionEntry: { summary: "x" } }),
    { type: "session_compact" },
  );
});

test("巨型 session_before_compact 线框化后照常送达,不丢事件、不重置 epoch", async () => {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");
  const address = server.address();
  assert.notEqual(typeof address, "string");
  assert.ok(address && typeof address !== "string");

  const frames: Frame[] = [];
  server.on("connection", (socket: WebSocket) => {
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

  const pi = {
    getThinkingLevel: () => "high",
    getCommands: () => [],
    sendUserMessage() {},
    async setModel() {
      return true;
    },
    setThinkingLevel: () => {},
  } as unknown as ExtensionAPI;
  const ctx = {
    mode: "tui",
    cwd: "/tmp/pipilot-compact-frame-test",
    model: undefined,
    ui: { setStatus() {} },
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
      getTree: () => [],
      getSessionId: () => "in-memory-session",
      getSessionFile: () => undefined,
      getSessionName: () => "Test",
      getLeafId: () => "entry-1",
    },
    modelRegistry: { getAvailable: () => [], find: () => undefined },
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
    const epoch = registration.snapshot.epoch as string;

    relay.setStreaming(true, ctx);
    relay.emitBoundary({ type: "agent_start" }, ctx);

    // pi 0.83.0 自动压缩的真实负载:branchEntries 是整段会话(这里 ~1.5MB),
    // 必超单帧 1MiB 预算被静默丢掉;signal 是宿主侧 AbortSignal,
    // 序列化出来是个无用的 {},同样不该上路。
    const fat = "A".repeat(150_000);
    const branchEntries = Array.from({ length: 10 }, (_, i) => ({
      type: "message",
      id: `e${i}`,
      parentId: i === 0 ? null : `e${i - 1}`,
      timestamp: i,
      message: { role: i % 2 ? "assistant" : "user", content: fat, timestamp: i },
    }));
    const hugeRaw = {
      type: "session_before_compact",
      preparation: { messagesToSummarize: 10, tokensBefore: 120000 },
      branchEntries,
      customInstructions: undefined,
      reason: "overflow",
      willRetry: true,
      signal: new AbortController().signal,
    };
    // 与 index.ts 处理器完全一致的三步(事件先过 compactEventFrame)。
    relay.setCompacting(true, ctx);
    relay.emitBoundary(compactEventFrame(hugeRaw), ctx);
    relay.snapshot(ctx);

    const compactEvent = await waitFor(() =>
      frames.find(
        (frame) =>
          frame.type === "desktop_event" && frame.event?.type === "session_before_compact",
      ),
    );
    assert.equal(
      compactEvent.epoch,
      epoch,
      "事件必须落在原 epoch 上 —— 丢事件 + epoch 重置会让手机晚一个周期",
    );
    assert.equal(compactEvent.seq, 2, "agent_start 之后紧接着就是压缩事件,序号不断档");
    assert.deepEqual(compactEvent.event, {
      type: "session_before_compact",
      reason: "overflow",
      willRetry: true,
    });
    assert.ok(
      JSON.stringify(compactEvent).length < 1024,
      "线框化后的事件必须是小帧,不能再带着整段会话上路",
    );

    const compactingSnapshot = await waitFor(() =>
      frames.find(
        (frame) =>
          frame.type === "desktop_snapshot" && frame.snapshot?.state?.isCompacting === true,
      ),
    );
    assert.equal(compactingSnapshot.snapshot.epoch, epoch, "快照也不许换 epoch");

    // 打断路径:合成 compaction_end 同样小、同 epoch、序号连续。
    relay.setStreaming(false, ctx);
    relay.finishCompaction(ctx, { aborted: true });
    const end = await waitFor(() =>
      frames.find(
        (frame) => frame.type === "desktop_event" && frame.event?.type === "compaction_end",
      ),
    );
    assert.equal(end.epoch, epoch);
    assert.equal(end.seq, 3);
    assert.equal(end.event.aborted, true);
  } finally {
    relay.dispose();
    server.close();
  }
});
