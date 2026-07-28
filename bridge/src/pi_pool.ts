import crypto from "node:crypto";
import { PiProcess } from "./pi_process.js";
import type { BridgeConfig } from "./config.js";
import { buildPiArgs, buildPiArgsForSessionPath } from "./config.js";
import type { JsonObject } from "./hub_protocol.js";

export interface SessionSpec {
  sessionId: string;
  cwd: string;
  /** 会话文件在默认目录之外时才需要。 */
  sessionPath?: string;
}

export interface PoolEntry {
  sourceId: string;
  /** 会话内切换/fork 之后由 `rebind()` 更新。 */
  spec: SessionSpec;
  proc: PiProcess;
  /** 取代旧的全局 `headlessEnabled`:每个进程独立决定崩溃后是否重启。 */
  restartOnExit: boolean;
  restartCount: number;
  restartTimer?: NodeJS.Timeout;
  lastActivityMs: number;
  streaming: boolean;
  closing: boolean;
}

export interface PoolCallbacks {
  /** 当前有多少客户端在看这个 source(逐出与闲置回收都要看)。 */
  watchers(sourceId: string): number;
  /** 这个 source 上有多少在途请求。 */
  pendingCount(sourceId: string): number;
  onSpawn(entry: PoolEntry): void;
  onLine(entry: PoolEntry, line: string): void;
  onExit(entry: PoolEntry, code: number | null, signal: NodeJS.Signals | null): void;
  /** 逐出/关闭前通知,便于失败在途请求并广播离线。 */
  onClosing(entry: PoolEntry, reason: string): void;
  /** 反复崩溃后放弃热转:会话被移出池,下次 open 才会重新尝试。 */
  onDead?(entry: PoolEntry, reason: string): void;
}

/** 由会话 id 推导稳定的 sourceId,使游标能跨进程重启存活。 */
export function sourceIdForSession(sessionId: string): string {
  return `s:${sessionId}`;
}

/**
 * 多会话 pi 进程池。
 *
 * 核心不变量:**`open()` 永远不会 kill 任何东西**。
 * 切换会话 = attach 或 spawn,正在生成的会话既不会被逐出也不会被闲置回收
 * ——这正是「切换会话不打断电脑端生成」。
 */
export class PiPool {
  private readonly entries = new Map<string, PoolEntry>();
  /** sessionId → sourceId,防止两个 pi 进程打开同一个会话文件(会互相覆写)。 */
  private readonly claims = new Map<string, string>();
  /// sourceId 撞车时的去重计数(会话内切换过文件的进程会占着老 sourceId)。
  private sourceIdSeq = 0;

  constructor(
    private readonly config: BridgeConfig,
    private readonly callbacks: PoolCallbacks,
  ) {}

  get size(): number {
    return this.entries.size;
  }

  has(sourceId: string): boolean {
    return this.entries.has(sourceId);
  }

  get(sourceId: string): PoolEntry | undefined {
    return this.entries.get(sourceId);
  }

  list(): PoolEntry[] {
    return [...this.entries.values()];
  }

  /** 外部(桌面 relay)占用某个会话时登记,阻止池再为它开进程。 */
  claimExternal(sessionId: string, sourceId: string): void {
    this.claims.set(sessionId, sourceId);
  }

  releaseExternal(sessionId: string): void {
    if (this.claims.get(sessionId) && !this.entries.has(this.claims.get(sessionId)!)) {
      this.claims.delete(sessionId);
    }
  }

  /** attach 已有进程,或按需 spawn。绝不 kill 现有进程。 */
  open(spec: SessionSpec): PoolEntry {
    // 先查 claim:进程可能因为会话内 switch/fork 换过文件,那时它的 sourceId
    // 已经不再等于 sourceIdForSession(sessionId),只有 claim 表知道谁持有它。
    const claimed = this.claims.get(spec.sessionId);
    if (claimed) {
      const existing = this.entries.get(claimed);
      if (!existing) {
        // claim 指向池外的持有者(桌面 relay)
        throw new Error("session is already open elsewhere");
      }
      if (existing.closing) throw new Error("session is shutting down; retry shortly");
      existing.lastActivityMs = Date.now();
      if (!existing.proc.alive) existing.proc.start();
      return existing;
    }

    this.evictIfNeeded();
    if (this.liveCount() >= this.config.maxLiveSessions) {
      throw new Error("too many live sessions");
    }

    // 稳定 sourceId 让客户端游标能跨进程重启存活;只有当它已经被一个
    // 换过会话的进程占着时,才退化成一个唯一 id。
    let sourceId = sourceIdForSession(spec.sessionId);
    if (this.entries.has(sourceId)) sourceId = `${sourceId}#${++this.sourceIdSeq}`;

    const args = spec.sessionPath
      ? buildPiArgsForSessionPath(spec.sessionPath, this.config.piFlagOpts)
      : buildPiArgs(spec.sessionId, this.config.piFlagOpts);
    const proc = new PiProcess(args, spec.cwd);
    const entry: PoolEntry = {
      sourceId,
      spec,
      proc,
      restartOnExit: true,
      restartCount: 0,
      lastActivityMs: Date.now(),
      streaming: false,
      closing: false,
    };
    proc.onSpawn = () => {
      entry.lastActivityMs = Date.now();
      this.callbacks.onSpawn(entry);
    };
    proc.onLine = (line) => {
      entry.lastActivityMs = Date.now();
      this.callbacks.onLine(entry, line);
    };
    proc.onExit = (code, signal) => {
      entry.streaming = false;
      this.callbacks.onExit(entry, code, signal);
      if (entry.closing || !entry.restartOnExit || proc.isIntentionalStop) return;
      if (entry.restartCount >= 5) {
        // 反复崩溃就放弃热转,并移出池 —— 下次 open() 会重新尝试一次干净的 spawn
        this.forget(entry);
        this.callbacks.onDead?.(entry, "pi process kept crashing");
        return;
      }
      const delay = Math.min(30_000, 1500 * 2 ** entry.restartCount);
      entry.restartCount++;
      entry.restartTimer = setTimeout(() => {
        entry.restartTimer = undefined;
        if (!entry.closing) proc.start();
      }, delay);
      entry.restartTimer.unref();
    };

    this.entries.set(sourceId, entry);
    this.claims.set(spec.sessionId, sourceId);
    proc.start();
    return entry;
  }

  /// 正在关闭的 entry 不再占容量:它的 claim 还在(保护会话文件),
  /// 但进程已经在退出路上,不该挡住新会话。
  private liveCount(): number {
    let count = 0;
    for (const entry of this.entries.values()) {
      if (!entry.closing) count++;
    }
    return count;
  }

  private forget(entry: PoolEntry): void {
    if (this.entries.get(entry.sourceId) === entry) this.entries.delete(entry.sourceId);
    if (this.claims.get(entry.spec.sessionId) === entry.sourceId) {
      this.claims.delete(entry.spec.sessionId);
    }
  }

  /**
   * 进程在会话内换了文件(`switch_session` / `fork` / `clone` / `new_session`)。
   *
   * 不重新绑定的话 claims 表会指向一个这个进程已经不再持有的会话,
   * 于是别人能为那个会话再开一个 pi —— 同一个文件两个写入方。
   */
  rebind(sourceId: string, sessionId: string, sessionPath?: string): void {
    const entry = this.entries.get(sourceId);
    if (!entry || entry.spec.sessionId === sessionId) return;
    if (this.claims.get(entry.spec.sessionId) === sourceId) {
      this.claims.delete(entry.spec.sessionId);
    }
    const conflicting = this.claims.get(sessionId);
    if (conflicting && conflicting !== sourceId) {
      // 另一个进程已经持有目标会话:这是个真实冲突,必须让调用方看到
      throw new Error("session is already open elsewhere");
    }
    entry.spec = { ...entry.spec, sessionId, sessionPath };
    this.claims.set(sessionId, sourceId);
  }

  /** 一次成功往返后清零崩溃计数。 */
  noteHealthy(sourceId: string): void {
    const entry = this.entries.get(sourceId);
    if (entry) entry.restartCount = 0;
  }

  setStreaming(sourceId: string, value: boolean): void {
    const entry = this.entries.get(sourceId);
    if (!entry) return;
    entry.streaming = value;
    entry.lastActivityMs = Date.now();
  }

  touch(sourceId: string): void {
    const entry = this.entries.get(sourceId);
    if (entry) entry.lastActivityMs = Date.now();
  }

  send(sourceId: string, message: JsonObject): boolean {
    const entry = this.entries.get(sourceId);
    if (!entry || !entry.proc.alive) return false;
    entry.lastActivityMs = Date.now();
    return entry.proc.send(message);
  }

  async close(sourceId: string, reason: string): Promise<void> {
    const entry = this.entries.get(sourceId);
    if (!entry || entry.closing) return;
    entry.closing = true;
    entry.restartOnExit = false;
    if (entry.restartTimer) clearTimeout(entry.restartTimer);
    this.callbacks.onClosing(entry, reason);
    try {
      // **进程真的死掉之前不能松开 claim**:SIGTERM 到 SIGKILL 之间最多 2 秒,
      // 这段时间里若 open() 看不到 claim,就会为同一个会话文件再拉起一个 pi,
      // 两个进程交替 append 会直接写坏会话。
      await entry.proc.stopAndWait(2000);
    } finally {
      this.forget(entry);
    }
  }

  /// 闲置回收候选:必须不在生成、没有观察者、没有在途请求,且超过 TTL。
  idleCandidates(now: number): string[] {
    const ttl = this.config.sessionIdleTtlMs;
    return this.evictionCandidates()
      .filter((entry) => now - entry.lastActivityMs > ttl)
      .map((entry) => entry.sourceId);
  }

  /// 逐出最久未活动的可逐出项。
  ///
  /// **正在生成、有人在看、有在途请求的会话都不是候选** —— 逐出与闲置回收
  /// 用的是同一套判据,否则"打开第 5 个会话"会悄悄杀掉别人正在读的第 1 个。
  private evictIfNeeded(): void {
    if (this.liveCount() < this.config.maxLiveSessions) return;
    const victim = this.evictionCandidates()[0];
    if (victim) void this.close(victim.sourceId, "evicted for a new session");
  }

  private evictionCandidates(): PoolEntry[] {
    return this.list()
      .filter(
        (entry) =>
          !entry.streaming &&
          !entry.closing &&
          this.callbacks.watchers(entry.sourceId) === 0 &&
          this.callbacks.pendingCount(entry.sourceId) === 0,
      )
      .sort((a, b) => a.lastActivityMs - b.lastActivityMs);
  }

  async shutdownAll(): Promise<void> {
    const all = this.list();
    this.entries.clear();
    this.claims.clear();
    await Promise.allSettled(
      all.map((entry) => {
        entry.closing = true;
        entry.restartOnExit = false;
        if (entry.restartTimer) clearTimeout(entry.restartTimer);
        return entry.proc.stopAndWait(2000);
      }),
    );
  }

  /** 进程崩溃退出路径的兜底:同步 SIGKILL,不等待。 */
  killAllSync(): void {
    for (const entry of this.entries.values()) {
      entry.closing = true;
      entry.restartOnExit = false;
      if (entry.restartTimer) clearTimeout(entry.restartTimer);
      entry.proc.killSync();
    }
    this.entries.clear();
  }

  /** 为新会话生成一个 id(调用方负责持久化到 dirSessions)。 */
  static newSessionId(): string {
    return crypto.randomUUID();
  }
}
