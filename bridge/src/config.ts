import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeP2pSignalingUrl } from "./p2p_signaling_url.js";

const bridgeRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const BRIDGE_CONFIG_PATH = path.join(bridgeRoot, "config.json");
const legacySessionIdPath = path.join(bridgeRoot, ".session-id");

export interface PiFlagOpts {
  provider?: string;
  model?: string;
  thinking?: string;
  sessionName: string;
}

export interface BridgeConfig {
  host: string;
  port: number;
  token: string;
  desktopToken: string;
  tokenGenerated: boolean;
  piCwd: string;
  piArgs: string[];
  sessionId: string;
  piFlagOpts: PiFlagOpts;
  dirSessions: Record<string, string>;
  headlessSourceId: string;
  headlessSourceName: string;
  headlessAutoStart: boolean;
  replayCapacity: number;
  /// 重放环的字节上限:单纯加大条数是错的杠杆——每条 message_update 都携带完整消息。
  replayByteBudget: number;
  snapshotRequestTimeoutMs: number;
  /// 桌面 relay 静默多久算死。Ctrl+Z(SIGTSTP)会冻住 pi 进程但内核 socket
  /// 仍是 ESTABLISHED、不发 FIN,所以 close 事件永远不来——只能靠
  /// 「多久没收到帧」判定。relay 心跳 10s 一次,取 3 次为死。
  desktopStaleMs: number;
  /// 桌面源断开多久后从列表里摘掉。断开不立刻删是为了留重连窗口:
  /// 同 epoch 重连能复用快照与重放环,不必强制全量重同步。
  desktopPruneMs: number;
  /// 同时存活的 pi 进程上限(并发会话)。
  maxLiveSessions: number;
  /// 无人观察且空闲多久后回收进程。正在生成的会话永不回收。
  sessionIdleTtlMs: number;
  leaseMinTtlMs: number;
  leaseMaxTtlMs: number;
  /// P2P(打洞)远程通道:bridge 作为 WebRTC host 挂到信令服上,
  /// 手机经信令服交换 SDP/ICE 后在 DataChannel 上跑同一套 hub 协议。
  p2p: P2pConfig;
}

export interface P2pConfig {
  enabled: boolean;
  /// 信令服地址(公网 VPS / 域名)。只交换握手,不碰会话流量。
  rendezvousUrl: string;
  /// 这台桌面在信令服上的名字;手机凭它找到本机。
  deviceId: string;
  /// 配对密钥:与信令服 devices 表里的值一致。挑战-应答校验,永不上行。
  secret: string;
}

interface FileConfig {
  token?: string;
  desktopToken?: string;
  dirSessions?: Record<string, string>;
  /// P2P 打洞配置也可写在 config.json(此文件在 bridge/.gitignore 中,
  /// 密钥不会进仓库;writeFileConfig 以 0600 权限落盘)。
  /// 优先级:CLI 参数 > 环境变量 > 本文件。
  p2p?: {
    enabled?: boolean;
    rendezvousUrl?: string;
    deviceId?: string;
    secret?: string;
  };
}

function readFileConfig(): FileConfig {
  try {
    return JSON.parse(fs.readFileSync(BRIDGE_CONFIG_PATH, "utf8")) as FileConfig;
  } catch {
    return {};
  }
}

/** Merge-patch bridge/config.json (mode 0600). Best-effort. */
export function writeFileConfig(patch: Partial<FileConfig>): void {
  const next = { ...readFileConfig(), ...patch };
  try {
    fs.writeFileSync(BRIDGE_CONFIG_PATH, JSON.stringify(next, null, 2) + "\n", { mode: 0o600 });
    fs.chmodSync(BRIDGE_CONFIG_PATH, 0o600);
  } catch (err) {
    console.error("[bridge] failed to persist config.json:", err);
  }
}

export function buildPiArgs(sessionId: string, opts: PiFlagOpts): string[] {
  const args = ["--mode", "rpc", "--session-id", sessionId, "--name", opts.sessionName];
  if (opts.provider) args.push("--provider", opts.provider);
  if (opts.model) args.push("--model", opts.model);
  if (opts.thinking) args.push("--thinking", opts.thinking);
  return args;
}

export function buildPiArgsForSessionPath(
  sessionPath: string,
  opts: PiFlagOpts,
): string[] {
  const args = ["--mode", "rpc", "--session", sessionPath, "--name", opts.sessionName];
  if (opts.provider) args.push("--provider", opts.provider);
  if (opts.model) args.push("--model", opts.model);
  if (opts.thinking) args.push("--thinking", opts.thinking);
  return args;
}

function parseArgv(argv: string[]): Map<string, string | boolean> {
  const out = new Map<string, string | boolean>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a || !a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith("--")) {
      out.set(key, next);
      i++;
    } else {
      out.set(key, true);
    }
  }
  return out;
}

function readLegacySessionId(): string | undefined {
  try {
    const existing = fs.readFileSync(legacySessionIdPath, "utf8").trim();
    return existing || undefined;
  } catch {
    return undefined;
  }
}

function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export function loadConfig(): BridgeConfig {
  const args = parseArgv(process.argv.slice(2));
  const str = (key: string): string | undefined => {
    const value = args.get(key);
    return typeof value === "string" ? value : undefined;
  };
  const file = readFileConfig();

  // 默认双栈:"::" 同时接收 IPv6 与 v4-mapped 连接(IPv6 直连的前提);
  // IPv6 被禁用的机器由 server 在监听失败时回退 0.0.0.0。
  const host = str("host") ?? process.env.PIPILOT_HOST ?? "::";
  const port = positiveInt(str("port") ?? process.env.PIPILOT_PORT, 9377);

  let token = str("token") ?? process.env.PIPILOT_TOKEN ?? file.token ?? "";
  let tokenGenerated = false;
  if (!token) {
    token = crypto.randomBytes(24).toString("base64url");
    tokenGenerated = true;
    writeFileConfig({ token });
  }

  let desktopToken =
    str("desktop-token") ?? process.env.PIPILOT_DESKTOP_TOKEN ?? file.desktopToken ?? "";
  if (!desktopToken) {
    desktopToken = crypto.randomBytes(32).toString("base64url");
    writeFileConfig({ desktopToken });
  }

  const piCwd = str("pi-cwd") ?? process.env.PI_CWD ?? process.cwd();
  const piFlagOpts: PiFlagOpts = {
    provider: str("provider"),
    model: str("model"),
    thinking: str("thinking"),
    sessionName: str("session-name") ?? "PiPilot",
  };

  const p2pRendezvous = normalizeP2pSignalingUrl(
    str("p2p-rendezvous") ??
      process.env.PIPILOT_P2P_RENDEZVOUS ??
      file.p2p?.rendezvousUrl ??
      "",
  );
  const p2pSecret =
    str("p2p-secret") ??
    process.env.PIPILOT_P2P_SECRET ??
    file.p2p?.secret ??
    "";

  const dirSessions: Record<string, string> = { ...(file.dirSessions ?? {}) };
  const sessionId =
    str("session-id") ?? dirSessions[piCwd] ?? readLegacySessionId() ?? crypto.randomUUID();
  if (dirSessions[piCwd] !== sessionId) {
    dirSessions[piCwd] = sessionId;
    writeFileConfig({ dirSessions });
  }

  return {
    host,
    port,
    token,
    desktopToken,
    tokenGenerated,
    piCwd,
    piArgs: buildPiArgs(sessionId, piFlagOpts),
    sessionId,
    piFlagOpts,
    dirSessions,
    headlessSourceId: process.env.PIPILOT_HEADLESS_SOURCE_ID ?? "headless:local",
    headlessSourceName: process.env.PIPILOT_HEADLESS_SOURCE_NAME ?? "Local headless pi",
    headlessAutoStart: process.env.PIPILOT_HEADLESS_AUTO_START === "true",
    replayCapacity: positiveInt(process.env.PIPILOT_REPLAY_CAPACITY, 1024),
    replayByteBudget: positiveInt(
      process.env.PIPILOT_REPLAY_BYTES,
      16 * 1024 * 1024,
    ),
    snapshotRequestTimeoutMs: positiveInt(
      process.env.PIPILOT_SNAPSHOT_TIMEOUT_MS,
      4_000,
    ),
    desktopStaleMs: positiveInt(process.env.PIPILOT_DESKTOP_STALE_MS, 30_000),
    desktopPruneMs: positiveInt(process.env.PIPILOT_DESKTOP_PRUNE_MS, 300_000),
    maxLiveSessions: positiveInt(process.env.PIPILOT_MAX_PI_PROCESSES, 4),
    sessionIdleTtlMs: positiveInt(
      process.env.PIPILOT_SESSION_IDLE_TTL_MS,
      900_000,
    ),
    // 强制抢占后,TTL 只负责释放死客户端的 fence,可以做得很短
    leaseMinTtlMs: positiveInt(process.env.PIPILOT_LEASE_MIN_TTL_MS, 3_000),
    leaseMaxTtlMs: positiveInt(process.env.PIPILOT_LEASE_MAX_TTL_MS, 8_000),
    p2p: {
      // 默认:配了信令服地址和配对密钥就开;显式 PIPILOT_P2P_ENABLED=false
      // 或 config.json 里 p2p.enabled=false 可关。
      enabled:
        process.env.PIPILOT_P2P_ENABLED !== undefined
          ? process.env.PIPILOT_P2P_ENABLED === "true"
          : (file.p2p?.enabled ?? Boolean(p2pRendezvous && p2pSecret)),
      rendezvousUrl: p2pRendezvous,
      deviceId:
        str("p2p-device-id") ??
        process.env.PIPILOT_P2P_DEVICE_ID ??
        file.p2p?.deviceId ??
        os.hostname(),
      secret: p2pSecret,
    },
  };
}

export function lanUrls(config: BridgeConfig): string[] {
  const urls: string[] = [`ws://127.0.0.1:${config.port}`, `ws://[::1]:${config.port}`];
  const ifaces = os.networkInterfaces();
  for (const list of Object.values(ifaces)) {
    for (const addr of list ?? []) {
      if (addr.internal) continue;
      if (addr.family === "IPv4") {
        urls.push(`ws://${addr.address}:${config.port}`);
      } else if (addr.family === "IPv6" && !addr.address.startsWith("fe80:")) {
        // 全局/ULA 地址直接展示,手机抄进设置就能连;link-local(fe80:)没意义
        urls.push(`ws://[${addr.address}]:${config.port}`);
      }
    }
  }
  return urls;
}
