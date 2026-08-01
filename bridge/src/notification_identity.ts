import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/// 通知事件的持久化根目录。与 pi 的 agent 数据同域,便于备份策略统一。
export const NOTIFICATION_DIR = path.join(os.homedir(), ".pi", "agent", "pipilot");
const IDENTITY_FILE = "bridge-identity.json";

/// `SourceRegistry.hubId` 是进程级 UUID(每次启动都变),它可以继续服务旧的
/// source cursor,但不能作为「跨重启识别同一台 Bridge」的身份 —— 手机在 DHCP
/// 换址后要靠一个稳定值确认「还是原来那台机器」。所以这里单独落一份持久身份。
///
/// 注意:本模块不替换 hubId,两者并存。见 stable-plan.md §3.2 的双字段过渡方案。
export interface BridgeIdentityV1 {
  schema: 1;
  /// 首次启动生成的高熵随机值,此后永不变。
  bridgeInstallationId: string;
  /// 事件库的世代。event store 被重置/删除时换新值,让客户端能识别
  /// 「sequence 从头开始了」而不是误接到旧 cursor 上。
  eventEpoch: string;
  createdAt: string;
}

function isValidIdentity(value: unknown): value is BridgeIdentityV1 {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<BridgeIdentityV1>;
  return (
    record.schema === 1 &&
    typeof record.bridgeInstallationId === "string" &&
    record.bridgeInstallationId.length > 0 &&
    typeof record.eventEpoch === "string" &&
    record.eventEpoch.length > 0 &&
    typeof record.createdAt === "string"
  );
}

function newIdentity(): BridgeIdentityV1 {
  return {
    schema: 1,
    // 32 字节随机而非 randomUUID:UUID v4 只有 122 bit 熵且格式可预测,
    // 这个值会出现在 mDNS TXT 里,给足熵更稳妥。
    bridgeInstallationId: `bridge-${crypto.randomBytes(32).toString("base64url")}`,
    eventEpoch: crypto.randomUUID(),
    createdAt: new Date().toISOString(),
  };
}

/// 原子写:先写临时文件并 fsync,再 rename。避免断电后留下半截 JSON,
/// 那会让 Bridge 在下次启动时丢掉身份、被手机当成另一台机器。
function writeIdentityAtomic(filePath: string, identity: BridgeIdentityV1): void {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${filePath}.tmp-${process.pid}`;
  const payload = JSON.stringify(identity, null, 2) + "\n";
  const fd = fs.openSync(tmp, "w", 0o600);
  try {
    fs.writeFileSync(fd, payload);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, filePath);
  // 目录项本身也要落盘,否则 rename 可能在崩溃后丢失。
  try {
    const dirFd = fs.openSync(dir, "r");
    try {
      fs.fsyncSync(dirFd);
    } finally {
      fs.closeSync(dirFd);
    }
  } catch {
    // 某些平台不允许 fsync 目录;rename 本身已是原子操作,可接受。
  }
}

export interface LoadIdentityResult {
  identity: BridgeIdentityV1;
  /// 本次是否新建。调用方据此决定是否要提示「这是一台新 Bridge」。
  created: boolean;
}

/// 读取或创建持久身份。损坏的文件不静默覆盖成新身份 —— 那会让所有已配对
/// 手机的 cursor 变成孤儿。改为重命名备份后再建新的,让问题可追溯。
export function loadBridgeIdentity(baseDir: string = NOTIFICATION_DIR): LoadIdentityResult {
  const filePath = path.join(baseDir, IDENTITY_FILE);
  let raw: string | undefined;
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") {
      // 读不出来但文件可能存在(权限/IO 错误):不能当成「没有身份」直接新建,
      // 那会让所有已配对手机的 cursor 变成孤儿。抛出去让启动失败更安全。
      console.error("[notify] failed to read bridge identity:", err);
      throw err;
    }
    const identity = newIdentity();
    writeIdentityAtomic(filePath, identity);
    return { identity, created: true };
  }

  // 文件存在:解析失败与结构非法都必须先备份再新建,不能静默覆盖。
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = undefined;
  }
  if (isValidIdentity(parsed)) return { identity: parsed, created: false };

  const backup = `${filePath}.corrupt-${Date.now()}`;
  try {
    fs.renameSync(filePath, backup);
    console.error(
      `[notify] bridge identity was malformed; moved to ${backup}. Paired clients must re-confirm.`,
    );
  } catch (err) {
    console.error("[notify] failed to back up malformed bridge identity:", err);
  }
  const identity = newIdentity();
  writeIdentityAtomic(filePath, identity);
  return { identity, created: true };
}

/// event store 被重置时换 epoch。sequence 会从 0 重新开始,客户端必须
/// 收到 cursor_expired{reason:"store_reset"} 而不是静默接到旧 cursor 上。
export function rotateEventEpoch(
  baseDir: string = NOTIFICATION_DIR,
  current?: BridgeIdentityV1,
): BridgeIdentityV1 {
  const filePath = path.join(baseDir, IDENTITY_FILE);
  const base = current ?? loadBridgeIdentity(baseDir).identity;
  const next: BridgeIdentityV1 = { ...base, eventEpoch: crypto.randomUUID() };
  writeIdentityAtomic(filePath, next);
  return next;
}
