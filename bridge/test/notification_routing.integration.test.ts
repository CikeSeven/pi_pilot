import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";

type Frame = Record<string, any>;

/// 这个测试锁住一个真机联调才暴露的路由缺陷。
///
/// server.ts 按类型前缀分流消息:hub_* 走 handleHubCommand,bridge_* 走
/// handleBridgeCommand,其余全部落到 handleSourceCommand。notification_* 的
/// 处理分支写在 handleHubCommand 里,但前缀既不是 hub_ 也不是 bridge_,
/// 于是被当成 source 命令转发,撞上 requireSelectedSource 的守卫,
/// 返回 "select a source first"。
///
/// 单元测试覆盖不到这里:它们直接调 NotificationSubscriptionManager,
/// 绕过了整个路由层。所以这条回归必须走真实进程 + 真实 WebSocket。
///
/// 关键语义:通知订阅绝不能依赖「已选 source」。手机在后台时根本没有
/// 选中的 source,而那恰恰是最需要收到通知的时刻。

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

test("notification_* frames route to the hub handler without a selected source", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  // 独立 HOME:身份文件与 outbox 都走 os.homedir(),不能污染真实数据,
  // 也不能与并发运行的 Bridge 争抢同一个 JSONL(store 是单串行写者)。
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-routing-"));
  const child = spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
    cwd: bridgeRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
      PIPILOT_HOST: "127.0.0.1",
      PIPILOT_PORT: String(port),
      PIPILOT_TOKEN: "routing-test-token",
      PIPILOT_DESKTOP_TOKEN: "routing-desktop-token",
      PIPILOT_P2P_DEVICE_ID: "routing-device",
      PIPILOT_HEADLESS_AUTO_START: "false",
      PI_CWD: bridgeRoot,
    },
  });

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));

  try {
    await waitForHealth(port, child);
    const ws = new WebSocket(
      `ws://127.0.0.1:${port}/?token=routing-test-token&clientId=routing-probe`,
    );
    const peer = new Peer(ws);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", resolve);
      ws.once("error", reject);
    });

    const hello = await peer.waitFor((frame) => frame.type === "bridge_hello");
    // 双字段过渡:旧 hubId 必须保留,新字段同时出现。
    assert.equal(typeof hello.hubId, "string");
    assert.match(hello.bridgeInstallationId, /^bridge-/);
    assert.equal(typeof hello.eventEpoch, "string");
    assert.ok(hello.capabilities.includes("notification_events_v1"));
    assert.ok(hello.capabilities.includes("notification_receipts_v1"));

    // 刻意**不**发 hub_select_source。这正是回归点。
    const subscribed = await peer.request("notification_subscribe", {
      installationId: "routing-install",
      scopeVersion: 1,
      pageLimit: 100,
    });
    assert.equal(
      subscribed.success,
      true,
      `notification_subscribe 不该依赖已选 source,却得到: ${subscribed.error}`,
    );
    assert.notEqual(subscribed.error, "select a source first");

    // 空库应当直接 ready:没有待追平的事件。
    await peer.waitFor((frame) => frame.type === "notification_ready");

    // ack 与 receipt 同样不该被 source 守卫拦下。
    const acked = await peer.request("notification_ack", {
      installationId: "routing-install",
      eventEpoch: hello.eventEpoch,
      through: 0,
    });
    assert.notEqual(acked.error, "select a source first");

    const receipted = await peer.request("notification_receipt", {
      installationId: "routing-install",
      eventId: "00000000-0000-4000-8000-000000000000",
      state: "display_confirmed",
      at: new Date().toISOString(),
    });
    assert.equal(receipted.success, true, `receipt 被拒: ${receipted.error}`);

    // terminate 而不是 close:close 要等对端回 FIN,
    // 残留的 socket 句柄会把 node:test 的事件循环一直吊住。
    ws.terminate();
  } finally {
    child.kill("SIGKILL");
    // 等子进程真正回收,再销毁 stdio 管道。
    //
    // 只 kill 是不够的:spawn 的 pipe 句柄仍然挂在事件循环上,
    // 测试会 518ms 就断言通过、然后进程永不退出,直到外部超时。
    await new Promise<void>((resolve) => {
      if (child.exitCode !== null || child.signalCode !== null) return resolve();
      child.once("exit", () => resolve());
      setTimeout(resolve, 2_000);
    });
    child.stdout?.destroy();
    child.stderr?.destroy();
    fs.rmSync(home, { recursive: true, force: true });
    if (stderr.includes("Error") && !stderr.includes("SIGKILL")) {
      // 便于诊断:只在真出错时把 stderr 带出来。
      console.error("[routing test] bridge stderr:", stderr.slice(-1500));
    }
  }
});
