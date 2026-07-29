import fs from "node:fs";
import path from "node:path";

/** 信令服配置。真实值放 config.json(gitignore),仓库里只有 config.example.json。 */
export interface RendezvousConfig {
  port: number;
  host: string;
  /** deviceId -> 配对密钥(挑战-应答校验,密钥本身从不上行) */
  devices: Record<string, string>;
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
  return {
    port: Number(process.env.PIPILOT_RDV_PORT ?? raw.port ?? 9378),
    host: (process.env.PIPILOT_RDV_HOST as string | undefined) ?? (raw.host as string | undefined) ?? "0.0.0.0",
    devices,
  };
}
