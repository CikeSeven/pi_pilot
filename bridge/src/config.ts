import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

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
  leaseMinTtlMs: number;
  leaseMaxTtlMs: number;
}

interface FileConfig {
  token?: string;
  desktopToken?: string;
  dirSessions?: Record<string, string>;
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

  const host = str("host") ?? process.env.PIPILOT_HOST ?? "0.0.0.0";
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
    replayCapacity: positiveInt(process.env.PIPILOT_REPLAY_CAPACITY, 512),
    leaseMinTtlMs: positiveInt(process.env.PIPILOT_LEASE_MIN_TTL_MS, 5_000),
    leaseMaxTtlMs: positiveInt(process.env.PIPILOT_LEASE_MAX_TTL_MS, 30_000),
  };
}

export function lanUrls(config: BridgeConfig): string[] {
  const urls: string[] = [`ws://127.0.0.1:${config.port}`];
  const ifaces = os.networkInterfaces();
  for (const list of Object.values(ifaces)) {
    for (const addr of list ?? []) {
      if (addr.family === "IPv4" && !addr.internal) {
        urls.push(`ws://${addr.address}:${config.port}`);
      }
    }
  }
  return urls;
}
