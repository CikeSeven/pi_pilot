import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";

type Frame = Record<string, any>;

/// 这条回归锁住一个 API 报错时暴露的误报:
///
/// pi 在可重试的 API 错误后也会先发 agent_end(带 willRetry),然后才
/// auto_retry_start → 退避 → 重试的 agent_start。修复前
/// noteStreamingFromEvent 见 agent_end 就把 streaming 翻 false 并触发
/// detector.onTaskEnd —— 手机立刻收到「任务完成」,而电脑端其实还在
/// 自动重试,紧接着又一轮 agent_start。
///
/// 修复后:agent_end(willRetry: true) 不翻边沿、不生成完成事件;
/// 收口交给重试后的最终 agent_end / agent_settled,整轮只产出一条
/// task_completed。

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

const SOURCE_ID = "willretry-source";
const TOKEN = "willretry-test-token";
const DESKTOP_TOKEN = "willretry-desktop-token";

function snapshot(epoch: string, isStreaming: boolean): Frame {
  return {
    epoch,
    baseSeq: 0,
    state: { sessionId: "willretry-session", isStreaming },
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
      PIPILOT_P2P_DEVICE_ID: "willretry-device",
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
    `ws://127.0.0.1:${port}/desktop?token=${DESKTOP_TOKEN}&clientId=willretry-desktop`,
  );
  sockets.push(ws);
  const peer = new Peer(ws);
  await new Promise<void>((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  return peer;
}

function completedEvents(peer: Peer): Frame[] {
  return peer.frames
    .filter((f) => f.type === "notification_events" && Array.isArray(f.events))
    .flatMap((f) => f.events as Frame[])
    .filter((e) => e.type === "task_completed");
}

test("agent_end(willRetry) 不产完成事件,重试后的最终结束才产一条", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-willretry-"));
  let bridge: ChildProcess | undefined;
  // socket 必须在 finally 里清:断言失败时走不到 try 末尾的 terminate,
  // 泄漏的句柄会把 node:test 的事件循环永久吊住。
  const sockets: WebSocket[] = [];

  try {
    bridge = spawnBridge(port, home, bridgeRoot);
    await waitForHealth(port, bridge);

    // 手机先连上订阅,才能观察实时推送的完成事件。
    const phone = new WebSocket(
      `ws://127.0.0.1:${port}/?token=${TOKEN}&clientId=willretry-phone`,
    );
    sockets.push(phone);
    const phonePeer = new Peer(phone);
    await new Promise<void>((resolve, reject) => {
      phone.once("open", resolve);
      phone.once("error", reject);
    });
    await phonePeer.waitFor((frame) => frame.type === "bridge_hello");
    const subscribed = await phonePeer.request("notification_subscribe", {
      installationId: "willretry-install",
      scopeVersion: 1,
      pageLimit: 100,
    });
    assert.equal(subscribed.success, true, `订阅失败: ${subscribed.error}`);
    await phonePeer.waitFor((frame) => frame.type === "notification_ready");

    const desktop = await openDesktop(port, sockets);
    desktop.send({
      type: "desktop_register",
      source: {
        sourceId: SOURCE_ID,
        label: "willretry",
        cwd: bridgeRoot,
        sessionId: "willretry-session",
        capabilities: [],
      },
      snapshot: snapshot("e1", false),
    });
    const registered = await desktop.waitFor(
      (frame) => frame.type === "desktop_registered" || frame.type === "desktop_error",
    );
    assert.equal(
      registered.type,
      "desktop_registered",
      `desktop_register 失败: ${registered.error}`,
    );

    // 第一轮:agent_start → agent_end(willRetry: true)。
    // API 报错后电脑端会自动重试,这里不得产出完成事件。
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 1, event: { type: "agent_start" } });
    await new Promise((resolve) => setTimeout(resolve, 200));
    desktop.send({
      type: "desktop_event",
      epoch: "e1",
      seq: 2,
      event: { type: "agent_end", willRetry: true },
    });
    await new Promise((resolve) => setTimeout(resolve, 400));
    assert.equal(
      completedEvents(phonePeer).length,
      0,
      "agent_end(willRetry) 不得产出完成事件",
    );

    // 重试:agent_start 紧随(边沿没翻过 false,不应开新代次),
    // 最终 agent_end 不带 willRetry —— 此刻才收口,恰好产出一条。
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 3, event: { type: "agent_start" } });
    await new Promise((resolve) => setTimeout(resolve, 200));
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 4, event: { type: "agent_end" } });
    const events = await phonePeer.waitFor(
      (frame) =>
        frame.type === "notification_events" &&
        Array.isArray(frame.events) &&
        frame.events.some((e: Frame) => e.type === "task_completed"),
      6_000,
    );
    const completed = (events.events as Frame[]).filter((e) => e.type === "task_completed");
    assert.equal(completed.length, 1, "重试后的最终 agent_end 应恰好产出一条完成事件");

    // agent_settled 紧随其后不得再产出第二条(代次去重)。
    desktop.send({ type: "desktop_event", epoch: "e1", seq: 5, event: { type: "agent_settled" } });
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(
      completedEvents(phonePeer).length,
      1,
      "agent_end + agent_settled 只应产出一条完成事件",
    );

    phone.terminate();
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
