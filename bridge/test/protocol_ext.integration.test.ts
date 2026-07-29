import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";

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
      // Still binding.
    }
    if (Date.now() - started > 5_000) throw new Error("hub health check timed out");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function spawnHub(
  port: number,
  bridgeRoot: string,
  extraEnv: Record<string, string> = {},
): ChildProcess {
  return spawn(path.join(bridgeRoot, "node_modules", ".bin", "tsx"), ["src/server.ts"], {
    cwd: bridgeRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      PIPILOT_HOST: "127.0.0.1",
      PIPILOT_PORT: String(port),
      PIPILOT_TOKEN: "mobile-test-token",
      PIPILOT_DESKTOP_TOKEN: "desktop-test-token",
      PIPILOT_HEADLESS_AUTO_START: "false",
      PIPILOT_PI_BIN: process.execPath,
      PI_CWD: bridgeRoot,
      ...extraEnv,
    },
  });
}

function onceExit(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => child.once("exit", () => resolve()));
}

test("pong echo, desktop snapshot reads, and extension_ui_response gating", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot);

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const desktop = await open(`ws://127.0.0.1:${port}/desktop?token=desktop-test-token`);
    peers.push(desktop);
    await desktop.waitFor((frame) => frame.type === "desktop_hello");
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:test",
          label: "Test desktop",
          cwd: "/tmp/pipilot-ext-test",
          sessionId: "session-test",
          capabilities: [
            "prompt",
            "abort",
            "set_model",
            "set_thinking_level",
            "set_session_name",
            "tree-summary-on-demand",
          ],
        },
        snapshot: {
          epoch: "epoch-test",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-test", isStreaming: false },
          entries: [],
          leafId: "leaf-1",
          stats: { tokens: { input: 10, output: 5, total: 15 }, cost: 0.12 },
          commands: [{ name: "commit", description: "commit changes", source: "extension" }],
          // 故意不带 treeSummary:真实长会话的快照正是这个形态。
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");

    // bridge_ping echo 回传
    phone.ws.send(JSON.stringify({ type: "bridge_ping", echo: 12345 }));
    const pong = await phone.waitFor((frame) => frame.type === "bridge_pong");
    assert.equal(pong.echo, 12345);

    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:test" })).success,
      true,
    );

    // 无 lease 的快照只读命令
    const stats = await phone.request("get_session_stats");
    assert.equal(stats.success, true);
    assert.equal(stats.data.cost, 0.12);

    const commands = await phone.request("get_commands");
    assert.equal(commands.success, true);
    assert.equal(commands.data.commands[0].name, "commit");

    // 快照没有 treeSummary 时,Hub 必须向桌面 relay 独立取树,不能再直接报
    // "desktop snapshot does not include a tree"。
    const treePromise = phone.request("get_tree");
    const treeRequest = await desktop.waitFor(
      (frame) => frame.type === "desktop_tree_request",
    );
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_tree",
        requestId: treeRequest.requestId,
        epoch: "epoch-test",
        tree: [{ id: "leaf-1", type: "message", timestamp: 1, children: [] }],
        leafId: "leaf-1",
      }),
    );
    const tree = await treePromise;
    assert.equal(tree.success, true);
    assert.equal(tree.data.summary, true);
    assert.equal(tree.data.tree[0].id, "leaf-1");
    assert.equal(tree.data.leafId, "leaf-1");

    // 取树失败必须带回 relay 给的原因。全部塌缩成一句「不可用」的话,
    // 手机上看不出到底是超预算、ctx 失效还是 epoch 不一致。
    const failPromise = phone.request("get_tree");
    // waitFor 是从累积帧里从头找的,必须排除上一次已结算的 requestId。
    const failRequest = await desktop.waitFor(
      (frame) =>
        frame.type === "desktop_tree_request" && frame.requestId !== treeRequest.requestId,
    );
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_tree_unavailable",
        requestId: failRequest.requestId,
        reason: "stale_ctx",
      }),
    );
    const failed = await failPromise;
    assert.equal(failed.success, false);
    assert.match(failed.error, /stale_ctx/);

    // extension_ui_response:无 lease 拒绝
    const noLease = await phone.request("extension_ui_response", {
      uiRequestId: "ui-1",
      value: "pick",
    });
    assert.equal(noLease.success, false);

    // 有 lease 但 desktop source → 干净拒绝
    const acquired = await phone.request("hub_acquire_owner", { ttlMs: 10_000 });
    assert.equal(acquired.success, true);
    const desktopDenied = await phone.request("extension_ui_response", {
      uiRequestId: "ui-1",
      value: "pick",
      _hub: { leaseId: acquired.data.leaseId, fence: acquired.data.fence },
    });
    assert.equal(desktopDenied.success, false);
    assert.match(desktopDenied.error, /TUI/);
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

test("extension_ui_response reaches headless pi and broadcasts extension_ui_answered", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawn(
    path.join(bridgeRoot, "node_modules", ".bin", "tsx"),
    ["src/server.ts"],
    {
      cwd: bridgeRoot,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PIPILOT_HOST: "127.0.0.1",
        PIPILOT_PORT: String(port),
        PIPILOT_TOKEN: "mobile-test-token",
        PIPILOT_DESKTOP_TOKEN: "desktop-test-token",
        PIPILOT_HEADLESS_AUTO_START: "false",
        // 假 pi:node fixtures/fake_pi.mjs(PiProcess 的 args 原样传给该脚本)
        PIPILOT_PI_BIN: path.join(bridgeRoot, "test", "fixtures", "fake_pi_wrapper.sh"),
        PI_CWD: bridgeRoot,
      },
    },
  );

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const phoneA = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    const phoneB = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phoneA, phoneB);
    await phoneA.waitFor((frame) => frame.type === "bridge_hello");

    const listed = await phoneA.request("hub_list_sources");
    const headless = listed.data.sources.find((source: Frame) => source.kind === "headless");
    assert.ok(headless);
    assert.equal(
      (await phoneA.request("hub_select_source", { sourceId: headless.id })).success,
      true,
    );
    assert.equal(
      (await phoneB.request("hub_select_source", { sourceId: headless.id })).success,
      true,
    );

    // 显式打开会话才拉起 headless(假 pi);acquire 本身没有任何进程副作用
    const opened = await phoneA.request("hub_open_session", {
      sessionId: headless.sessionId,
      cwd: headless.cwd,
    });
    assert.equal(opened.success, true);
    const acquired = await phoneA.request("hub_acquire_owner", { ttlMs: 10_000 });
    assert.equal(acquired.success, true);
    await phoneA.waitFor(
      (frame) => frame.type === "hub_sources_changed" &&
        frame.sources?.some((source: Frame) => source.kind === "headless" && source.connected),
      8_000,
    );

    const lease = { leaseId: acquired.data.leaseId, fence: acquired.data.fence };
    const delivered = await phoneA.request("extension_ui_response", {
      uiRequestId: "dialog-7",
      value: "option-a",
      _hub: lease,
    });
    assert.equal(delivered.success, true);
    assert.equal(delivered.data.delivered, true);

    // 假 pi 收到帧后回发 extension_ui_echo 事件(经 hub 广播)
    const echo = await phoneA.waitFor((frame) => frame.type === "extension_ui_echo", 8_000);
    assert.equal(echo.receivedId, "dialog-7");
    assert.equal(echo.value, "option-a");

    // 其他客户端收到 extension_ui_answered 撤卡片事件
    const answeredB = await phoneB.waitFor(
      (frame) => frame.type === "extension_ui_answered",
      8_000,
    );
    assert.equal(answeredB.requestId, "dialog-7");
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit; stderr: ${stderr}`)), 5_000),
      ),
    ]);
  }
});

/// Ctrl+Z 发的是 SIGTSTP:pi 进程被冻住,但内核 socket 仍是 ESTABLISHED 且不发
/// FIN,所以 `ws.on("close")` 永远不触发。只靠连接状态判断的话,旧源会永久停在
/// connected=true,App 既不会切走、抽屉里那一行也永远不消失。
///
/// 这里用一条「注册后就再不发任何帧」的桌面连接模拟被冻住的 relay:
/// 先必须被判死(connected=false),随后必须被摘出源列表。
test("silent desktop relay is declared dead and then pruned", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot, {
    PIPILOT_DESKTOP_STALE_MS: "600",
    PIPILOT_DESKTOP_PRUNE_MS: "600",
  });

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const desktop = await open(`ws://127.0.0.1:${port}/desktop?token=desktop-test-token`);
    peers.push(desktop);
    await desktop.waitFor((frame) => frame.type === "desktop_hello");
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:frozen",
          label: "Frozen desktop",
          cwd: "/tmp/pipilot-frozen",
          sessionId: "session-frozen",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-frozen",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-frozen", isStreaming: false },
          entries: [],
          leafId: "leaf-1",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");

    const listed = await phone.request("hub_list_sources");
    assert.equal(
      listed.data.sources.some(
        (source: Frame) => source.id === "desktop:frozen" && source.connected === true,
      ),
      true,
    );

    // 此后这条连接一个字都不发(等同于被 SIGTSTP 冻住)。
    // 判死:必须先变成 connected=false。
    await phone.waitFor(
      (frame) =>
        frame.type === "hub_sources_changed" &&
        frame.sources.some(
          (source: Frame) => source.id === "desktop:frozen" && source.connected === false,
        ),
      8_000,
    );

    // 回收:超过 prune 窗口后必须从列表里彻底消失,否则每次 Ctrl+Z 都永久留一行。
    await phone.waitFor(
      (frame) =>
        frame.type === "hub_sources_changed" &&
        !frame.sources.some((source: Frame) => source.id === "desktop:frozen"),
      8_000,
    );

    const after = await phone.request("hub_list_sources");
    assert.equal(
      after.data.sources.some((source: Frame) => source.id === "desktop:frozen"),
      false,
    );
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit; stderr: ${stderr}`)), 5_000),
      ),
    ]);
  }
});

test("an in-flight questionnaire is republished when a client selects the source", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot);

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const desktop = await open(`ws://127.0.0.1:${port}/desktop?token=desktop-test-token`);
    peers.push(desktop);
    await desktop.waitFor((frame) => frame.type === "desktop_hello");
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:ask",
          label: "Ask desktop",
          cwd: "/tmp/pipilot-ask",
          sessionId: "session-ask",
          capabilities: ["prompt", "ask-user-question-relay"],
        },
        snapshot: {
          epoch: "epoch-ask",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-ask", isStreaming: false },
          entries: [],
          leafId: "leaf-1",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    // relay 的门控是「有手机在看这个源」,所以要先有一个观众。
    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:ask" })).success,
      true,
    );

    desktop.ws.send(
      JSON.stringify({
        type: "desktop_ask_request",
        requestId: "ask:1",
        epoch: "epoch-ask",
        toolCallId: "call-1",
        questions: [
          {
            question: "缓存放在哪一层?",
            header: "缓存层",
            options: [{ label: "Redis", description: "跨进程共享" }],
          },
        ],
      }),
    );
    const first = await phone.waitFor(
      (frame) => frame.type === "ask_user_question_request",
    );
    assert.equal(first.requestId, "ask:1");
    assert.equal(first.toolCallId, "call-1");

    // 重连/换源后必须重新看见这份问卷。重放环不够用:断层大到回落整份快照时,
    // 那条 hub 注入的本地事件就跟着丢了,于是电脑还在 beforeToolCall 上等,
    // 手机却什么都没有,谁也动不了,直到作答窗口超时。
    const late = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(late);
    await late.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(
      (await late.request("hub_select_source", { sourceId: "desktop:ask" })).success,
      true,
    );
    const republished = await late.waitFor(
      (frame) => frame.type === "ask_user_question_request",
    );
    assert.equal(republished.requestId, "ask:1");
    assert.equal(republished.questions[0].question, "缓存放在哪一层?");
    // 问卷帧必须是带外的:一旦占了源的 seq,桌面源下一条事件就会被判
    // sequence_gap(recordDesktopEvent 要求 seq === lastSeq + 1,而 seq 由 relay
    // 自己独立递增),于是 hub 回 desktop_resync_required、relay 换 epoch 重发
    // 全量快照、App 整份重同步 —— 答完题后永无止境地重连。
    assert.equal(republished._hub, undefined);
    assert.equal(first._hub, undefined);

    // 作答后要撤卡,别的客户端也得收到撤卡事件。
    assert.equal(
      (await late.request("ask_response", {
        requestId: "ask:1",
        answers: [{ question: "缓存放在哪一层?", labels: ["Redis"] }],
      })).success,
      true,
    );
    const result = await desktop.waitFor((frame) => frame.type === "desktop_ask_result");
    assert.equal(result.requestId, "ask:1");
    assert.equal(result.answers[0].labels[0], "Redis");
    await phone.waitFor(
      (frame) =>
        frame.type === "ask_user_question_retracted" && frame.requestId === "ask:1",
    );
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit; stderr: ${stderr}`)), 5_000),
      ),
    ]);
  }
});

test("mobile snapshots are clipped to a byte budget and older history pages back", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot);

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const desktop = await open(`ws://127.0.0.1:${port}/desktop?token=desktop-test-token`);
    peers.push(desktop);
    await desktop.waitFor((frame) => frame.type === "desktop_hello");

    // 300 条 x 约 8KB ≈ 2.4MB。远超 1MB 的手机预算,也远超 2MB 套接字缓冲上限
    // 所对应的危险区间 —— 真实长会话实测过 9.78MB / 4592 条。
    const filler = "x".repeat(8_000);
    const entries = Array.from({ length: 300 }, (_, i) => ({
      id: `e${i}`,
      type: "message",
      timestamp: i + 1,
      message: { role: i % 2 === 0 ? "user" : "assistant", content: filler, timestamp: i + 1 },
    }));

    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:big",
          label: "Big desktop",
          cwd: "/tmp/pipilot-big",
          sessionId: "session-big",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-big",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-big", isStreaming: false },
          entries,
          leafId: "e299",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:big" })).success,
      true,
    );

    // hub_sync 必须只发尾巴。整帧一旦超过 2MB,巨包本身发得出去,但紧接着的任何
    // 一次发送都会看到 bufferedAmount 超限而 close(1013) —— 手机于是约 2 秒
    // 一轮地重连,永远同步不完。
    const sync = await phone.request("hub_sync");
    assert.equal(sync.success, true);
    assert.equal(sync.data.mode, "snapshot");
    const sent = sync.data.snapshot.entries;
    assert.ok(sent.length < entries.length, "整份 300 条不该原样发给手机");
    assert.ok(
      Buffer.byteLength(JSON.stringify(sync)) < 2 * 1024 * 1024,
      "hub_sync 整帧必须留在 2MB 套接字缓冲之内",
    );
    // 尾巴要对齐到最后一条,否则聊天页显示的不是最新消息
    assert.equal(sent[sent.length - 1].id, "e299");
    assert.equal(sync.data.entriesHasMore, true);
    assert.equal(sync.data.entriesOmitted, entries.length - sent.length);
    assert.equal(sync.data.entriesOldestId, sent[0].id);

    // 条数下限优先于字节预算:单条 entry 实测最大能到 1.16MB,只按字节封顶会在
    // 这种条目面前退化成只发 1 条,聊天页就只剩一句话。
    assert.ok(sent.length >= 80, `至少要给 80 条,实际 ${sent.length}`);

    // 往前分页:返回游标之前那段的**尾巴**,才能与已显示的内容接上。
    const older = await phone.request("get_entries", { before: sync.data.entriesOldestId });
    assert.equal(older.success, true);
    const olderEntries = older.data.entries;
    assert.ok(olderEntries.length > 0);
    // 紧邻游标,中间不能有洞
    const cursorIndex = entries.findIndex((e) => e.id === sync.data.entriesOldestId);
    assert.equal(olderEntries[olderEntries.length - 1].id, `e${cursorIndex - 1}`);
    assert.ok(
      Buffer.byteLength(JSON.stringify(older)) < 2 * 1024 * 1024,
      "分页应答也必须留在缓冲之内",
    );

    // limit 能进一步收窄
    const small = await phone.request("get_entries", {
      before: sync.data.entriesOldestId,
      limit: 5,
    });
    assert.equal(small.success, true);
    assert.equal(small.data.entries.length, 5);
    assert.equal(small.data.hasMore, true);

    // 一路翻到头:hasMore 必须落回 false,否则按钮永远留在那儿骗人
    let cursor: string | null = sync.data.entriesOldestId;
    let guard = 0;
    let sawEnd = false;
    while (cursor && guard++ < 20) {
      const page = await phone.request("get_entries", { before: cursor });
      assert.equal(page.success, true);
      if (page.data.hasMore !== true) {
        sawEnd = true;
        assert.equal(page.data.entries[0].id, "e0", "最后一页要一直翻到第一条");
        break;
      }
      cursor = page.data.oldestId;
    }
    assert.equal(sawEnd, true, "应当能翻到历史开头");

    // 游标不存在时要明确报错,而不是静默给空数组(那会让 App 以为到头了)
    const bogus = await phone.request("get_entries", { before: "nope" });
    assert.equal(bogus.success, false);
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit; stderr: ${stderr}`)), 5_000),
      ),
    ]);
  }
});

test("streaming flips broadcast refreshed sessions so keepalive counts stay fresh", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot);

  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    await waitForHealth(port, child);
    const desktop = await open(`ws://127.0.0.1:${port}/desktop?token=desktop-test-token`);
    peers.push(desktop);
    await desktop.waitFor((frame) => frame.type === "desktop_hello");
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:stream",
          label: "Stream desktop",
          cwd: "/tmp/pipilot-stream",
          sessionId: "session-stream",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-stream",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-stream", isStreaming: false },
          entries: [],
          leafId: "leaf-1",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");
    // select 会触发一次 notifySessionsChanged(streaming=false 的基准帧)。
    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:stream" })).success,
      true,
    );

    const streamingOf = (frame: Frame): boolean | undefined => {
      if (frame.type !== "hub_sessions_changed") return undefined;
      const sessions = Array.isArray(frame.sessions) ? frame.sessions : [];
      const found = sessions.find((s) => s?.sessionId === "session-stream");
      return found ? found.streaming === true : undefined;
    };

    // agent_start → streaming 翻成 true,sessions 广播必须立刻跟上,
    // 否则手机常驻通知的「工作中」计数停在 0。
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_event",
        sourceId: "desktop:stream",
        epoch: "epoch-stream",
        seq: 1,
        event: { type: "agent_start" },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_ack" && frame.seq === 1);
    const startBroadcast = await phone.waitFor(
      (frame) => streamingOf(frame) === true,
    );

    // agent_end → 翻回 false。注意 150ms 防抖:等 true 那轮广播结算完再发,
    // 否则两个翻转合并成一轮,中间态永远见不着。
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_event",
        sourceId: "desktop:stream",
        epoch: "epoch-stream",
        seq: 2,
        event: { type: "agent_end" },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_ack" && frame.seq === 2);
    // waitFor 从头扫累积帧:select 时的基准帧也是 streaming=false,
    // 必须排除掉 startBroadcast 之前(含)的所有帧。
    const startIdx = phone.frames.indexOf(startBroadcast);
    await phone.waitFor(
      (frame) => phone.frames.indexOf(frame) > startIdx && streamingOf(frame) === false,
    );
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`hub did not exit; stderr: ${stderr}`)), 5_000),
      ),
    ]);
  }
});

test("hub bound to '::' serves both IPv4 and IPv6 clients (dual-stack)", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot, { PIPILOT_HOST: "::" });
  let stderr = "";
  child.stderr?.on("data", (chunk) => (stderr += chunk.toString()));
  const peers: Peer[] = [];
  try {
    // waitForHealth 走 127.0.0.1 —— 它成功本身就是双栈下 v4 兼容的证明
    await waitForHealth(port, child);
    peers.push(await open(`ws://127.0.0.1:${port}/?token=mobile-test-token`));
    peers.push(await open(`ws://[::1]:${port}/?token=mobile-test-token`));
    const health6 = await fetch(`http://[::1]:${port}/health`);
    assert.ok(health6.ok, "IPv6 loopback health check");
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
