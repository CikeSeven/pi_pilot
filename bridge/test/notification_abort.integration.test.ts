import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";

type Frame = Record<string, any>;

/// 这条回归锁住「用户中断被误报成任务完成」:
///
/// 电脑端 Esc / 手机端停止都会让 pi 以 stopReason=aborted 的 assistant
/// 消息结束本轮并发出 agent_end。修复前 noteStreamingFromEvent 见
/// agent_end 就触发 detector.onTaskEnd —— 手机收到「任务完成」,
/// 但用户明明是主动中断的。
///
/// 修复后:agent_end(aborted) 翻 streaming 边沿但走 onTaskAborted,
/// 代次落为 cancelled —— 不产事件,Bridge 重启后也不会被
/// restoreGenerations 复活成过期的完成通知。

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

async function waitForHealth(port: number, child: ChildProcess): Promise<void> {
  const started = Date.now();
  for (;;) {
    if (child.exitCode !== null) throw new Error(`hub exited early with ${child.exitCode}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok) return;
    } catch {
      // 端口还没绑上。
    }
    if (Date.now() - started > 8_000) throw new Error("hub health check timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

class Peer {
  readonly frames: Frame[] = [];
  private readonly pending = new Map<string, (frame: Frame) => void>();

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

  request(type: string, extra: Frame = {}, id = `req-${this.frames.length}-${type}`): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`request timed out: ${type}`));
      }, 5_000);
      this.pending.set(id, (frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
      this.ws.send(JSON.stringify({ type, id, ...extra }));
    });
  }

  send(payload: Frame): void {
    this.ws.send(JSON.stringify(payload));
  }

  async waitFor(predicate: (frame: Frame) => boolean, timeoutMs = 5_000): Promise<Frame> {
    const started = Date.now();
    for (;;) {
      const found = this.frames.find(predicate);
      if (found) return found;
      if (Date.now() - started > timeoutMs) throw new Error("frame timed out");
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
}

const SOURCE_ID = "abort-source";
const TOKEN = "abort-test-token";
const DESKTOP_TOKEN = "abort-desktop-token";

function snapshot(epoch: string, isStreaming: boolean): Frame {
  return {
    epoch,
    baseSeq: 0,
    state: { sessionId: "abort-session", isStreaming },
    entries: [],
    leafId: null,
  };
}

function spawnBridge(port: number, home: string, bridgeRoot: string): ChildProcess {
  return spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
    cwd: bridgeRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
      PIPILOT_HOST: "127.0.0.1",
      PIPILOT_PORT: String(port),
      PIPILOT_TOKEN: TOKEN,
      PIPILOT_DESKTOP_TOKEN: DESKTOP_TOKEN,
      PIPILOT_P2P_DEVICE_ID: "abort-device",
      PIPILOT_HEADLESS_AUTO_START: "false",
      PI_CWD: bridgeRoot,
    },
  });
}

async function stopBridge(child: ChildProcess): Promise<void> {
  child.kill("SIGKILL");
  await new Promise<void>((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    child.once("exit", () => resolve());
    setTimeout(resolve, 2_000);
  });
  child.stdout?.destroy();
  child.stderr?.destroy();
}

async function openDesktop(port: number, sockets: WebSocket[]): Promise<Peer> {
  const ws = new WebSocket(
    `ws://127.0.0.1:${port}/desktop?token=${DESKTOP_TOKEN}&clientId=abort-desktop`,
  );
  sockets.push(ws);
  const peer = new Peer(ws);
  await new Promise<void>((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  return peer;
}

async function registerDesktop(desktop: Peer, bridgeRoot: string, epoch: string): Promise<void> {
  desktop.send({
    type: "desktop_register",
    source: {
      sourceId: SOURCE_ID,
      label: "abort",
      cwd: bridgeRoot,
      sessionId: "abort-session",
      capabilities: [],
    },
    snapshot: snapshot(epoch, false),
  });
  const registered = await desktop.waitFor(
    (frame) => frame.type === "desktop_registered" || frame.type === "desktop_error",
  );
  assert.equal(registered.type, "desktop_registered", `desktop_register 失败: ${registered.error}`);
}

async function subscribePhone(port: number, sockets: WebSocket[]): Promise<Peer> {
  const phone = new WebSocket(`ws://127.0.0.1:${port}/?token=${TOKEN}&clientId=abort-phone`);
  sockets.push(phone);
  const phonePeer = new Peer(phone);
  await new Promise<void>((resolve, reject) => {
    phone.once("open", resolve);
    phone.once("error", reject);
  });
  await phonePeer.waitFor((frame) => frame.type === "bridge_hello");
  const subscribed = await phonePeer.request("notification_subscribe", {
    installationId: "abort-install",
    scopeVersion: 1,
    pageLimit: 100,
  });
  assert.equal(subscribed.success, true, `订阅失败: ${subscribed.error}`);
  await phonePeer.waitFor((frame) => frame.type === "notification_ready");
  return phonePeer;
}

function completedEvents(peer: Peer): Frame[] {
  return peer.frames
    .filter((f) => f.type === "notification_events" && Array.isArray(f.events))
    .flatMap((f) => f.events as Frame[])
    .filter((e) => e.type === "task_completed");
}

test("中断不产完成事件,重启不复活,下一次正常完成恰好一条", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-abort-"));
  let bridge: ChildProcess | undefined;
  // socket 必须在 finally 里清:断言失败时走不到 try 末尾的 terminate,
  // 泄漏的句柄会把 node:test 的事件循环永久吊住。
  const sockets: WebSocket[] = [];

  try {
    bridge = spawnBridge(port, home, bridgeRoot);
    await waitForHealth(port, bridge);
    const phonePeer = await subscribePhone(port, sockets);
    let desktop = await openDesktop(port, sockets);
    await registerDesktop(desktop, bridgeRoot, "e1");

    // 第一轮:agent_start → agent_end(aborted)。用户中断,不得产完成事件。
    // 显式 aborted 标记(扩展路径)与 messages 派生(headless RPC 路径)
    // 都要认,这里覆盖显式标记。
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 1, event: { type: "agent_start" } });
    await new Promise((resolve) => setTimeout(resolve, 200));
    desktop.send({
      type: "desktop_event",
      epoch: "e1",
      seq: 2,
      event: { type: "agent_end", aborted: true },
    });
    await new Promise((resolve) => setTimeout(resolve, 400));
    assert.equal(completedEvents(phonePeer).length, 0, "中断不得产出完成事件");

    // ---- Bridge 重启:journal 里的代次是 cancelled,不能复活成 in_flight。
    // 修复前若中断只翻边沿不落代次,重启后 restoreGenerations 会把它当
    // 在飞任务恢复,下一个 agent_end 就会补发一条过期完成通知。
    desktop.ws.terminate();
    await stopBridge(bridge);
    bridge = undefined;

    bridge = spawnBridge(port, home, bridgeRoot);
    await waitForHealth(port, bridge);
    desktop = await openDesktop(port, sockets);
    await registerDesktop(desktop, bridgeRoot, "e2");

    // 第二轮:正常跑完一轮,应当恰好产出一条 —— 不多(中断那轮没残留),
    // 不少(正常完成不受影响)。
    desktop.send({ type: "desktop_event", epoch: "e2", seq: 1, event: { type: "agent_start" } });
    await new Promise((resolve) => setTimeout(resolve, 200));
    desktop.send({ type: "desktop_event", epoch: "e2", seq: 2, event: { type: "agent_end" } });
    const events = await phonePeer.waitFor(
      (frame) =>
        frame.type === "notification_events" &&
        Array.isArray(frame.events) &&
        frame.events.some((e: Frame) => e.type === "task_completed"),
      6_000,
    );
    const completed = (events.events as Frame[]).filter((e) => e.type === "task_completed");
    assert.equal(completed.length, 1, "重启后的正常完成应恰好一条");
    assert.equal(
      completedEvents(phonePeer).length,
      1,
      "中断那轮的代次不得在重启后补发完成事件",
    );

    desktop.ws.terminate();
  } finally {
    for (const ws of sockets) {
      try {
        ws.terminate();
      } catch {
        // 已关闭的 socket 忽略。
      }
    }
    if (bridge) await stopBridge(bridge);
  }
});

test("headless RPC 帧从 messages 派生 aborted 标记并随广播下发", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-abort-rpc-"));
  let bridge: ChildProcess | undefined;
  const sockets: WebSocket[] = [];

  try {
    bridge = spawnBridge(port, home, bridgeRoot);
    await waitForHealth(port, bridge);
    const phonePeer = await subscribePhone(port, sockets);
    const desktop = await openDesktop(port, sockets);
    await registerDesktop(desktop, bridgeRoot, "e1");

    // 广播的源事件只发给选中该源的客户端 —— 源注册完之后才能选中。
    const selected = await phonePeer.request("hub_select_source", { sourceId: SOURCE_ID });
    assert.equal(selected.success, true, `选中源失败: ${selected.error}`);

    // RPC 流的 agent_end 没有显式 aborted 字段,只有 messages ——
    // bridge 必须从最后一个 assistant 的 stopReason 派生。
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 1, event: { type: "agent_start" } });
    await new Promise((resolve) => setTimeout(resolve, 200));
    desktop.send({
      type: "desktop_event",
      epoch: "e1",
      seq: 2,
      event: {
        type: "agent_end",
        messages: [
          { role: "user", content: [] },
          { role: "assistant", stopReason: "aborted", content: [] },
        ],
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 400));
    assert.equal(completedEvents(phonePeer).length, 0, "messages 派生的中断也不得产完成事件");

    // 广播帧要带上注入的 aborted 标记 —— 手机端不再各自派生。
    const broadcast = phonePeer.frames.find(
      (f) => f.type === "agent_end" && f._hub !== undefined,
    );
    assert.equal(broadcast?.aborted, true, "广播帧应携带注入的 aborted 标记");

    desktop.ws.terminate();
  } finally {
    for (const ws of sockets) {
      try {
        ws.terminate();
      } catch {
        // 已关闭的 socket 忽略。
      }
    }
    if (bridge) await stopBridge(bridge);
  }
});
