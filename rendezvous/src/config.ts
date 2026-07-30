import fs from "node:fs";
import path from "node:path";

export interface TurnConfig {
  urls: string[];
  secret: string;
  ttlSeconds: number;
}

/** 信令服配置。真实值放 config.json(gitignore),仓库里只有 config.example.json。 */
export interface RendezvousConfig {
  port: number;
  host: string;
  /** deviceId -> 配对密钥(挑战-应答校验,密钥本身从不上行) */
  devices: Record<string, string>;
  /** STUN 仅做公网地址发现,不承载 DataChannel 会话数据。 */
  stunUrls?: string[];
  /** TURN 仅在直连失败时转发 DTLS 密文,凭据按次短期签发。 */
  turn?: TurnConfig;
}

export function normalizeStunUrls(value: unknown): string[] {
  const values = Array.isArray(value) ? value : typeof value === "string" ? value.split(",") : [];
  return Array.from(
    new Set(
      values
        .filter((item): item is string => typeof item === "string")
        .map((item) => item.trim())
        .filter((item) => item.startsWith("stun:") && item.length <= 512),
    ),
  ).slice(0, 4);
}

export function normalizeTurnConfig(value: unknown): TurnConfig | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const raw = value as Record<string, unknown>;
  const values = Array.isArray(raw.urls)
    ? raw.urls
    : typeof raw.urls === "string"
      ? raw.urls.split(",")
      : [];
  const urls = Array.from(
    new Set(
      values
        .filter((item): item is string => typeof item === "string")
        .map((item) => item.trim())
        .filter(
          (item) =>
            (item.startsWith("turn:") || item.startsWith("turns:")) && item.length <= 512,
        ),
    ),
  ).slice(0, 4);
  const secret = typeof raw.secret === "string" ? raw.secret.trim() : "";
  if (urls.length === 0 || secret.length < 16) return undefined;
  const parsedTtl = Number(raw.ttlSeconds ?? 600);
  const ttlSeconds = Number.isFinite(parsedTtl)
    ? Math.min(3_600, Math.max(60, Math.trunc(parsedTtl)))
    : 600;
  return { urls, secret, ttlSeconds };
}

export function loadConfig(root: string = process.cwd()): RendezvousConfig {
  const file = path.join(root, "config.json");
  const raw: Record<string, unknown> = fs.existsSync(file)
    ? (JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, unknown>)
    : {};
  const devices =
    typeof raw.devices === "object" && raw.devices !== null
      ? { ...(raw.devices as Record<string, string>) }
      : {};
  const rawTurn =
    typeof raw.turn === "object" && raw.turn !== null
      ? (raw.turn as Record<string, unknown>)
      : {};
  const turn = normalizeTurnConfig({
    urls: process.env.PIPILOT_RDV_TURN_URLS ?? rawTurn.urls,
    secret: process.env.PIPILOT_RDV_TURN_SECRET ?? rawTurn.secret,
    ttlSeconds: process.env.PIPILOT_RDV_TURN_TTL ?? rawTurn.ttlSeconds,
  });
  return {
    port: Number(process.env.PIPILOT_RDV_PORT ?? raw.port ?? 9378),
    host:
      (process.env.PIPILOT_RDV_HOST as string | undefined) ??
      (raw.host as string | undefined) ??
      "0.0.0.0",
    devices,
    stunUrls: normalizeStunUrls(process.env.PIPILOT_RDV_STUN_URLS ?? raw.stunUrls),
    turn,
  };
}
