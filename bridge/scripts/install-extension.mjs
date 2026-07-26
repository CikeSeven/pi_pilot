import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const bridgeRoot = path.resolve(scriptDir, "..");
const extensionRoot = path.resolve(bridgeRoot, "..", "extension");
const bridgeConfigPath = path.join(bridgeRoot, "config.json");
const agentDir = path.join(os.homedir(), ".pi", "agent");
const relayConfigPath = path.join(agentDir, "pipilot-sync.json");
const settingsPath = path.join(agentDir, "settings.json");
const configOnly = process.argv.includes("--config-only");

let bridgeConfig = {};
try {
  bridgeConfig = JSON.parse(fs.readFileSync(bridgeConfigPath, "utf8"));
} catch {
  // The first install creates bridge/config.json.
}
if (typeof bridgeConfig.desktopToken !== "string" || bridgeConfig.desktopToken.length < 16) {
  bridgeConfig.desktopToken = crypto.randomBytes(32).toString("base64url");
}
fs.writeFileSync(bridgeConfigPath, `${JSON.stringify(bridgeConfig, null, 2)}\n`, { mode: 0o600 });
fs.chmodSync(bridgeConfigPath, 0o600);

fs.mkdirSync(agentDir, { recursive: true, mode: 0o700 });
const port = Number(process.env.PIPILOT_PORT ?? 9377);
const relayConfig = {
  url: `ws://127.0.0.1:${Number.isSafeInteger(port) && port > 0 ? port : 9377}/desktop`,
  token: bridgeConfig.desktopToken,
};
fs.writeFileSync(relayConfigPath, `${JSON.stringify(relayConfig, null, 2)}\n`, { mode: 0o600 });
fs.chmodSync(relayConfigPath, 0o600);
console.log(`Configured desktop relay: ${relayConfigPath}`);

if (configOnly) process.exit(0);

let backupPath;
if (fs.existsSync(settingsPath)) {
  backupPath = `${settingsPath}.bak-pipilot-${Date.now()}`;
  fs.copyFileSync(settingsPath, backupPath);
  fs.chmodSync(backupPath, 0o600);
  console.log(`Backed up pi settings: ${backupPath}`);
}

const result = spawnSync("pi", ["install", extensionRoot], {
  stdio: "inherit",
  env: process.env,
});
if (result.status !== 0) {
  if (backupPath) fs.copyFileSync(backupPath, settingsPath);
  console.error("PiPilot extension installation failed; pi settings were restored.");
  process.exit(result.status ?? 1);
}

console.log("PiPilot desktop relay installed.");
console.log("Run /reload in each desktop pi TUI that should appear in PiPilot.");
console.log("Existing sessions were not opened or modified by this installer.");
