import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export interface RelayConfig {
  url: string;
  token: string;
  label?: string;
  reconnectMinMs: number;
  reconnectMaxMs: number;
  /// 流式期间每累积这么多事件就自发一次保活快照。
  streamSnapshotEvents: number;
  /// 流式期间距上次快照超过这么久就自发一次(即使事件不多)。
  streamSnapshotMaxMs: number;
}

interface FileConfig {
  url?: string;
  token?: string;
  label?: string;
  reconnectMinMs?: number;
  reconnectMaxMs?: number;
  streamSnapshotEvents?: number;
  streamSnapshotMaxMs?: number;
}

export const RELAY_CONFIG_PATH = path.join(os.homedir(), ".pi", "agent", "pipilot-sync.json");

function positiveInt(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : fallback;
}

export function loadRelayConfig(): RelayConfig | undefined {
  let file: FileConfig = {};
  try {
    file = JSON.parse(fs.readFileSync(RELAY_CONFIG_PATH, "utf8")) as FileConfig;
  } catch {
    // Environment variables may provide the complete configuration.
  }
  const rawUrl = process.env.PIPILOT_HUB_URL ?? file.url ?? "ws://127.0.0.1:9377/desktop";
  const token = process.env.PIPILOT_DESKTOP_TOKEN ?? file.token ?? "";
  if (!token) return undefined;

  const url = new URL(rawUrl);
  if (!(["ws:", "wss:"] as string[]).includes(url.protocol)) {
    throw new Error("PiPilot relay URL must use ws:// or wss://");
  }
  if (!["127.0.0.1", "localhost", "::1", "[::1]"].includes(url.hostname)) {
    throw new Error("PiPilot desktop relay must connect through loopback");
  }
  url.pathname = "/desktop";
  url.searchParams.set("token", token);

  return {
    url: url.toString(),
    token,
    label: process.env.PIPILOT_DESKTOP_LABEL ?? file.label,
    reconnectMinMs: positiveInt(file.reconnectMinMs, 500),
    reconnectMaxMs: positiveInt(file.reconnectMaxMs, 15_000),
    streamSnapshotEvents: positiveInt(file.streamSnapshotEvents, 192),
    streamSnapshotMaxMs: positiveInt(file.streamSnapshotMaxMs, 15_000),
  };
}
