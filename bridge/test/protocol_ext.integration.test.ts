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

test("手机快照把图片块和超长文本压小,小条目原样通过", async () => {
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

    // 82 条小消息( omitted=0,专门验证 capped 时也会换成浅拷贝的新数组)
    // + 1 条带 1.7MB base64 图片块的 read 结果 + 1 条 300KB 文本输出。
    const entries = [
      ...Array.from({ length: 80 }, (_, i) => ({
        id: `s${i}`,
        type: "message",
        timestamp: i + 1,
        message: { role: "user", content: `小消息 ${i}`, timestamp: i + 1 },
      })),
      {
        id: "img",
        type: "message",
        timestamp: 100,
        message: {
          role: "toolResult",
          toolName: "read",
          content: [
            { type: "text", text: "读取到图片文件" },
            { type: "image", data: "A".repeat(1_700_000), mimeType: "image/png" },
          ],
          timestamp: 100,
        },
      },
      {
        id: "huge",
        type: "message",
        timestamp: 101,
        message: {
          role: "toolResult",
          toolName: "bash",
          content: [{ type: "text", text: "y".repeat(300_000) }],
          timestamp: 101,
        },
      },
    ];

    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:cap",
          label: "Cap desktop",
          cwd: "/tmp/pipilot-cap",
          sessionId: "session-cap",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-cap",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-cap", isStreaming: false },
          entries,
          leafId: "huge",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:cap" })).success,
      true,
    );

    const sync = await phone.request("hub_sync");
    assert.equal(sync.success, true);
    const sent = sync.data.snapshot.entries;
    // 条数不变(82 > 条数下限 80,omitted=0),但巨型单条已被封顶。
    assert.equal(sent.length, 82);
    assert.equal(sync.data.entriesHasMore, undefined);
    assert.equal(sent[sent.length - 1].id, "huge");

    const img = sent.find((e) => e.id === "img");
    assert.equal(img.message.content.length, 2);
    assert.equal(img.message.content[0].text, "读取到图片文件");
    assert.deepEqual(img.message.content[1], {
      type: "text",
      text: "[图片等内容已在手机端省略,请在电脑上查看]",
    });

    const huge = sent.find((e) => e.id === "huge");
    const hugeText = huge.message.content[0].text;
    assert.ok(hugeText.startsWith("yyy"));
    assert.ok(
      hugeText.length < 70_000,
      `300KB 文本应被截到 64KB 级,实际 ${hugeText.length}`,
    );
    assert.ok(hugeText.endsWith("[过长内容已截断,完整内容在电脑上可见]"));

    // 小条目一个字都不能动
    const smallEntry = sent.find((e) => e.id === "s0");
    assert.equal(smallEntry.message.content, "小消息 0");

    // 整帧从 ~2MB 压到 200KB 以内,慢速链路才有机会传完。
    assert.ok(
      Buffer.byteLength(JSON.stringify(sync)) < 200 * 1024,
      "封顶后 hub_sync 整帧必须足够小",
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

test("msg-delta: 声明能力的客户端收增量帧,未声明的收全量", async () => {
  const port = await freePort();
  const bridgeRoot = path.resolve(import.meta.dirname, "..");
  const child = spawnHub(port, bridgeRoot);
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
          sourceId: "desktop:delta",
          label: "Delta desktop",
          cwd: "/tmp/pipilot-delta",
          sessionId: "session-delta",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-delta",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-delta", isStreaming: false },
          entries: [],
          leafId: "leaf-1",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const deltaPhone = await open(
      `ws://127.0.0.1:${port}?token=mobile-test-token&caps=msg-delta`,
    );
    const plainPhone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(deltaPhone, plainPhone);
    await Promise.all([
      deltaPhone.waitFor((frame) => frame.type === "bridge_hello"),
      plainPhone.waitFor((frame) => frame.type === "bridge_hello"),
    ]);
    assert.equal(
      (await deltaPhone.request("hub_select_source", { sourceId: "desktop:delta" })).success,
      true,
    );
    assert.equal(
      (await plainPhone.request("hub_select_source", { sourceId: "desktop:delta" })).success,
      true,
    );

    const sendUpdate = (seq: number, text: string, ts = 1): void => {
      desktop.ws.send(
        JSON.stringify({
          type: "desktop_event",
          sourceId: "desktop:delta",
          epoch: "epoch-delta",
          seq,
          event: {
            type: "message_update",
            message: {
              role: "assistant",
              timestamp: ts,
              content: [{ type: "text", text }],
            },
          },
        }),
      );
    };

    // 首帧:两边都必须收到全量 message_update(建立基线)。
    sendUpdate(1, "Hello");
    const firstDelta = await deltaPhone.waitFor(
      (frame) => frame.type === "message_update" && frame._hub?.seq === 1,
    );
    await plainPhone.waitFor(
      (frame) => frame.type === "message_update" && frame._hub?.seq === 1,
    );
    assert.equal(firstDelta.message.content[0].text, "Hello");

    // 前缀扩展:声明能力的收到 message_delta,未声明的仍收全量。
    sendUpdate(2, "Hello world");
    const deltaFrame = await deltaPhone.waitFor(
      (frame) => frame.type === "message_delta" && frame._hub?.seq === 2,
    );
    assert.equal(deltaFrame.key, "assistant:1");
    assert.equal(deltaFrame.blockIndex, 0);
    assert.equal(deltaFrame.field, "text");
    assert.equal(deltaFrame.appendText, " world");
    assert.equal(
      deltaPhone.frames.some(
        (frame) => frame.type === "message_update" && frame._hub?.seq === 2,
      ),
      false,
      "声明能力的客户端不该再收到同 seq 的全量帧",
    );
    const plainFull = await plainPhone.waitFor(
      (frame) => frame.type === "message_update" && frame._hub?.seq === 2,
    );
    assert.equal(plainFull.message.content[0].text, "Hello world");

    // 非前缀(内容改写):回退全量并重建基线。
    sendUpdate(3, "Hi there");
    const fallback = await deltaPhone.waitFor(
      (frame) => frame.type === "message_update" && frame._hub?.seq === 3,
    );
    assert.equal(fallback.message.content[0].text, "Hi there");

    // 再次前缀扩展:基线重建后又能出增量。
    sendUpdate(4, "Hi there!");
    const delta2 = await deltaPhone.waitFor(
      (frame) => frame.type === "message_delta" && frame._hub?.seq === 4,
    );
    assert.equal(delta2.appendText, "!");
  } finally {
    for (const peer of peers) peer.ws.close();
    child.kill("SIGTERM");
    await Promise.race([
      onceExit(child),
      new Promise((_, reject) => setTimeout(() => reject(new Error("hub did not exit")), 5_000)),
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

test("get_entries since 正向翻页:增量从头给、页间零丢失、tipId 锁边界", async () => {
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

    const entries = Array.from({ length: 300 }, (_, i) => ({
      id: `e${i}`,
      type: "message",
      timestamp: i + 1,
      message: { role: i % 2 === 0 ? "user" : "assistant", content: `消息 ${i}`, timestamp: i + 1 },
    }));
    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:fwd",
          label: "Forward desktop",
          cwd: "/tmp/pipilot-fwd",
          sessionId: "session-fwd",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-fwd",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-fwd", isStreaming: false },
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
      (await phone.request("hub_select_source", { sourceId: "desktop:fwd" })).success,
      true,
    );

    // 从 e49 之后开始正向翻,每页限 4KB 强制多页;收集的 id 必须恰好是
    // e50..e299 按序无洞 —— 旧的尾部裁剪行为会把前面的增量静默吞掉。
    let since: string | null = "e49";
    let tipId: string | undefined;
    const collected: string[] = [];
    let guard = 0;
    for (;;) {
      if (guard++ > 100) throw new Error("翻页超过 100 次,疑似死循环");
      const page = await phone.request("get_entries", {
        since,
        forward: true,
        limitBytes: 4096,
        ...(tipId ? { tipId } : {}),
      });
      assert.equal(page.success, true);
      tipId = page.data.tipId;
      assert.equal(tipId, "e299", "tip 应锁定在当前快照末尾");
      for (const entry of page.data.entries) collected.push(entry.id);
      if (page.data.hasMore !== true) break;
      since = page.data.nextSinceId;
      assert.ok(typeof since === "string" && since.length > 0, "hasMore 时必须给 nextSinceId");
    }
    assert.equal(collected.length, 250);
    for (let i = 0; i < 250; i++) {
      assert.equal(collected[i], `e${50 + i}`, `第 ${i} 条应是 e${50 + i}`);
    }

    // since 游标不存在仍然明确报错。
    const bogus = await phone.request("get_entries", { since: "nope", forward: true });
    assert.equal(bogus.success, false);
    // tipId 不存在同样明确报错,不允许默默退化成无界翻页。
    const badTip = await phone.request("get_entries", {
      since: "e49",
      forward: true,
      tipId: "nope",
    });
    assert.equal(badTip.success, false);
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

test("首屏字节预算是硬的:巨型单条被降级为 preview+contentRef,不得突破预算", async () => {
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

    // 关键构造:巨型单条由「很多个中等大小的块」堆成,每块都不触发字段级封顶
    // (单块 8000 字符 < MOBILE_ENTRY_TEXT_CAP 的 16K 字符),但整条序列化后
    // 约 240KB —— 远超单条硬上限。旧实现靠「至少给 N 条」兜底,这种条目会
    // 直接把首屏顶到几百 KB;慢 TURN 上传不完,表现为连上就超时重连。
    const fatBlocks = Array.from({ length: 30 }, (_, i) => ({
      type: "text",
      text: `块${i}:` + "z".repeat(8000),
    }));
    const entries = [
      ...Array.from({ length: 40 }, (_, i) => ({
        id: `t${i}`,
        type: "message",
        timestamp: i + 1,
        message: { role: "user", content: `尾部消息 ${i}`, timestamp: i + 1 },
      })),
      {
        id: "fat",
        type: "message",
        timestamp: 500,
        message: {
          role: "toolResult",
          toolName: "bash",
          content: fatBlocks,
          timestamp: 500,
        },
      },
    ];
    const fatRawBytes = Buffer.byteLength(JSON.stringify(entries[entries.length - 1]));
    assert.ok(
      fatRawBytes > 200 * 1024,
      `构造的巨型单条应远超硬上限,实际 ${fatRawBytes}B`,
    );

    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:hardcap",
          label: "Hard cap desktop",
          cwd: "/tmp/pipilot-hardcap",
          sessionId: "session-hardcap",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-hardcap",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-hardcap", isStreaming: false },
          entries,
          leafId: "fat",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:hardcap" })).success,
      true,
    );

    const sync = await phone.request("hub_sync");
    assert.equal(sync.success, true);
    const sent = sync.data.snapshot.entries as Record<string, unknown>[];

    // 巨型单条必须被降级,而不是原样塞进首屏。
    const fat = sent.find((e) => e.id === "fat");
    assert.ok(fat, "尾部那条必须还在(它是最新的)");
    assert.equal(fat!.contentTruncated, true, "超硬上限的单条必须被标记折叠");
    assert.deepEqual(
      fat!.contentRef,
      { entryId: "fat", bytes: fatRawBytes },
      "必须给出 contentRef 供按需取全文",
    );
    const fatSentBytes = Buffer.byteLength(JSON.stringify(fat));
    assert.ok(
      fatSentBytes < 8 * 1024,
      `降级后的单条应很小,实际 ${fatSentBytes}B`,
    );

    // 首屏 entries 总字节必须落在 P2P 硬预算之内(WS 走 1MB 预算,这里用
    // 更严的 P2P 数值断言:降级生效后即使按 P2P 预算也装得下)。
    const entriesBytes = Buffer.byteLength(JSON.stringify(sent));
    assert.ok(
      entriesBytes <= 128 * 1024,
      `首屏 entries 必须落在 128KiB 硬预算内,实际 ${entriesBytes}B`,
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

test("单条硬上限与 entry 形状无关:compaction(无 message)也必须被降级", async () => {
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

    // 关键构造:compaction 类型**根本没有 message 字段**,体积全在顶层
    // summary(字符串)与 details(对象)里。
    //
    // 这是真机上抓到的缺陷:字段级封顶(capEntryForMobile)与旧版硬上限
    // (hardCapEntryForMobile)都只看 entry.message,所以这类 entry 从两道
    // 「上限」下面完整穿过去。真机日志:
    //   entries_before{entries:1/1728,bytes:212673}
    // 单条 207KiB 把 96KiB 的页预算顶穿 2.2 倍。实测 50.40MB 的真实会话里
    // 有 35 条这样的 entry,最大单条 576,630B。
    const compaction = {
      id: "cmp",
      type: "compaction",
      parentId: "t39",
      timestamp: 500,
      summary: "摘要".repeat(60_000),
      firstKeptEntryId: "t10",
      tokensBefore: 123_456,
      details: {
        observations: Array.from({ length: 20 }, (_, i) => `观察${i}:` + "o".repeat(5_000)),
        reflections: Array.from({ length: 20 }, (_, i) => `反思${i}:` + "r".repeat(5_000)),
      },
      fromHook: false,
    };
    const compactionRawBytes = Buffer.byteLength(JSON.stringify(compaction));
    assert.ok(
      compactionRawBytes > 200 * 1024,
      `构造的 compaction 应远超硬上限,实际 ${compactionRawBytes}B`,
    );

    const entries = [
      ...Array.from({ length: 40 }, (_, i) => ({
        id: `t${i}`,
        type: "message",
        timestamp: i + 1,
        message: { role: "user", content: `尾部消息 ${i}`, timestamp: i + 1 },
      })),
      compaction,
    ];

    desktop.ws.send(
      JSON.stringify({
        type: "desktop_register",
        source: {
          sourceId: "desktop:shape",
          label: "Shape agnostic",
          cwd: "/tmp/pipilot-shape",
          sessionId: "session-shape",
          capabilities: ["prompt"],
        },
        snapshot: {
          epoch: "epoch-shape",
          baseSeq: 0,
          capturedAt: Date.now(),
          state: { sessionId: "session-shape", isStreaming: false },
          entries,
          leafId: "cmp",
        },
      }),
    );
    await desktop.waitFor((frame) => frame.type === "desktop_registered");

    const phone = await open(`ws://127.0.0.1:${port}?token=mobile-test-token`);
    peers.push(phone);
    await phone.waitFor((frame) => frame.type === "bridge_hello");
    assert.equal(
      (await phone.request("hub_select_source", { sourceId: "desktop:shape" })).success,
      true,
    );

    const sync = await phone.request("hub_sync");
    assert.equal(sync.success, true);
    const sent = sync.data.snapshot.entries as Record<string, unknown>[];

    const cmp = sent.find((e) => e.id === "cmp");
    assert.ok(cmp, "compaction 那条必须还在(它是最新的)");
    assert.equal(cmp!.contentTruncated, true, "没有 message 的巨型单条同样必须被折叠");
    assert.deepEqual(
      cmp!.contentRef,
      { entryId: "cmp", bytes: compactionRawBytes },
      "必须给出 contentRef 供按需取全文",
    );
    const cmpSentBytes = Buffer.byteLength(JSON.stringify(cmp));
    assert.ok(
      cmpSentBytes <= 64 * 1024,
      `降级后必须落在单条硬上限内,实际 ${cmpSentBytes}B`,
    );

    // 结构性字段必须留下:App 靠它们定位、建树、辨类型。
    assert.equal(cmp!.type, "compaction", "type 不得丢(App 据此渲染折叠卡)");
    assert.equal(cmp!.parentId, "t39", "parentId 不得丢(会话树要用)");
    assert.equal(cmp!.timestamp, 500, "timestamp 不得丢(排序要用)");

    // summary 是手机端唯一会显示的内容:必须留可读开头,不能整条丢掉。
    assert.equal(typeof cmp!.summary, "string", "summary 必须仍是字符串");
    assert.ok(
      (cmp!.summary as string).startsWith("摘要"),
      "summary 必须保留可读开头",
    );
    assert.ok(
      Buffer.byteLength(cmp!.summary as string) < 32 * 1024,
      "summary 必须被截断",
    );

    // details 手机端不渲染(只有 custom_message 用 details),整体省略即可。
    assert.notDeepEqual(cmp!.details, compaction.details, "details 不得原样过线");

    const entriesBytes = Buffer.byteLength(JSON.stringify(sent));
    assert.ok(
      entriesBytes <= 128 * 1024,
      `首屏 entries 必须落在 128KiB 硬预算内,实际 ${entriesBytes}B`,
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
