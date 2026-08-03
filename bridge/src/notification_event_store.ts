import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  isExpired,
  parseNotificationEvent,
  type NotificationEventV1,
} from "./notification_event.js";
import { NOTIFICATION_DIR } from "./notification_identity.js";

const STORE_FILE = "notification-outbox-v1.jsonl";

/// 压缩阈值。任一条件命中就重写日志。
export const DEFAULT_MAX_BYTES = 16 * 1024 * 1024;
export const DEFAULT_MAX_EVENTS = 10_000;
export const DEFAULT_TOMBSTONE_RATIO = 0.3;
/// 默认保留 7 天。未 ack 的 installation 不能无限阻止回收 ——
/// 一台再也不上线的手机不该让 Bridge 的日志无限增长。
export const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
/// 背压上限。事件生成速度可能超过落盘速度(任务风暴),必须有界。
export const DEFAULT_MAX_PENDING = 1_000;

/// 日志记录类型。event 不可变,其余都是状态转换。
type RecordKind = "event" | "ack" | "delivery" | "generation" | "tombstone";

interface WrappedRecord {
  k: RecordKind;
  /// 记录体的 SHA-256 前 16 hex。尾部半条记录可以靠它识别并跳过。
  c: string;
  d: unknown;
}

export interface AckRecord {
  installationId: string;
  eventEpoch: string;
  through: number;
  at: string;
}

export interface GenerationRecord {
  sourceId: string;
  taskGenerationId: string;
  /// completed 之后同一 generation 的 end/settled 不再生成新事件。
  /// cancelled 是用户中断的收口:不产事件,也不许重启后恢复成 in_flight。
  state: "in_flight" | "completed" | "cancelled";
  eventId?: string;
  at: string;
}

export interface StoreStats {
  events: number;
  bytes: number;
  tombstones: number;
  oldestEventAgeMs: number;
  compactions: number;
  corruptRecords: number;
  droppedBackpressure: number;
  /// fsync 失败计数。非 0 意味着「已宣称 persisted」的承诺有风险,必须告警。
  writeFailures: number;
  pending: number;
}

function checksum(payload: unknown): string {
  return crypto
    .createHash("sha256")
    .update(JSON.stringify(payload))
    .digest("hex")
    .slice(0, 16);
}

function wrap(kind: RecordKind, data: unknown): string {
  const record: WrappedRecord = { k: kind, c: checksum(data), d: data };
  return JSON.stringify(record) + "\n";
}

/// 解析并校验一行。checksum 不匹配就当损坏 —— 这比静默接受一条被截断
/// 或被编辑过的记录安全,后者会让 sequence 或 ack 悄悄错位。
function unwrap(line: string): { kind: RecordKind; data: unknown } | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (!parsed || typeof parsed !== "object") return undefined;
  const record = parsed as Partial<WrappedRecord>;
  if (typeof record.k !== "string" || typeof record.c !== "string") return undefined;
  if (record.d === undefined) return undefined;
  if (checksum(record.d) !== record.c) return undefined;
  return { kind: record.k as RecordKind, data: record.d };
}

export interface EventStoreOptions {
  baseDir?: string;
  maxBytes?: number;
  maxEvents?: number;
  tombstoneRatio?: number;
  retentionMs?: number;
  maxPending?: number;
  /// 测试用:注入可控时钟。
  now?: () => number;
  /// 测试用:在指定阶段抛错以模拟崩溃/磁盘故障。
  faultInjector?: (stage: "append" | "fsync" | "compact-write" | "compact-rename") => void;
}

/// 持久通知事件存储。
///
/// 为什么不复用 bridge/src/server.ts:645 的 op-log:那里是裸 appendFileSync
/// 包在空 catch 里,没有 fsync、没有 checksum、没有原子压缩,写失败被完全吞掉。
/// 它可以作为 append-only 的形态参考,但承载不了「事件不丢」的承诺。
///
/// 关键约束(stable-plan.md §6.2):
///  - 所有写入走单一串行 writer,禁止并发 append。
///  - 事件必须 append + fsync 成功后才能对客户端宣称 persisted。
///  - 写失败时保留 pending、停止宣称 persisted、持续告警,不静默吞掉。
export class NotificationEventStore {
  private readonly filePath: string;
  private readonly maxBytes: number;
  private readonly maxEvents: number;
  private readonly tombstoneRatio: number;
  private readonly retentionMs: number;
  private readonly maxPending: number;
  private readonly now: () => number;
  private readonly faultInjector?: (
    stage: "append" | "fsync" | "compact-write" | "compact-rename",
  ) => void;

  /// sequence -> event。用 Map 保持插入顺序,便于按 sequence 扫描。
  private readonly events = new Map<number, NotificationEventV1>();
  private readonly eventIdIndex = new Map<string, number>();
  private readonly acks = new Map<string, AckRecord>();
  private readonly generations = new Map<string, GenerationRecord>();
  private tombstones = 0;
  private compactions = 0;
  private corruptRecords = 0;
  private droppedBackpressure = 0;
  private writeFailures = 0;
  private lastSequence = 0;
  /// 落盘失败时事件停在这里。它们还没被宣称 persisted,不能进发送队列。
  private readonly pending: NotificationEventV1[] = [];
  private fd: number | undefined;
  private degraded = false;

  constructor(options: EventStoreOptions = {}) {
    const baseDir = options.baseDir ?? NOTIFICATION_DIR;
    this.filePath = path.join(baseDir, STORE_FILE);
    this.maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;
    this.maxEvents = options.maxEvents ?? DEFAULT_MAX_EVENTS;
    this.tombstoneRatio = options.tombstoneRatio ?? DEFAULT_TOMBSTONE_RATIO;
    this.retentionMs = options.retentionMs ?? DEFAULT_RETENTION_MS;
    this.maxPending = options.maxPending ?? DEFAULT_MAX_PENDING;
    this.now = options.now ?? Date.now;
    this.faultInjector = options.faultInjector;
    fs.mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  }

  // -------------------------------------------------------------------------
  // 启动恢复
  // -------------------------------------------------------------------------

  /// replay 日志。损坏的尾行忽略并告警,但绝不整库清空 ——
  /// 一次意外断电不该让用户丢掉全部未读通知。
  load(): void {
    let text: string;
    try {
      text = fs.readFileSync(this.filePath, "utf8");
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (code !== "ENOENT") {
        this.degraded = true;
        console.error("[notify] failed to read event store:", err);
      }
      return;
    }
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line === undefined || line.trim().length === 0) continue;
      const record = unwrap(line);
      if (record === undefined) {
        this.corruptRecords++;
        // 最后一行损坏通常是崩溃时写了半条,属预期;中间损坏更值得警惕。
        const isTail = i >= lines.length - 2;
        console.error(
          `[notify] skipping ${isTail ? "truncated tail" : "corrupt"} record at line ${i + 1}`,
        );
        continue;
      }
      this.applyRecord(record.kind, record.data);
    }
    this.pruneExpired();
  }

  private applyRecord(kind: RecordKind, data: unknown): void {
    switch (kind) {
      case "event": {
        const event = parseNotificationEvent(data);
        if (event === undefined) {
          this.corruptRecords++;
          return;
        }
        this.events.set(event.sequence, event);
        this.eventIdIndex.set(event.eventId, event.sequence);
        if (event.sequence > this.lastSequence) this.lastSequence = event.sequence;
        return;
      }
      case "ack": {
        const ack = data as Partial<AckRecord>;
        if (
          typeof ack.installationId !== "string" ||
          typeof ack.eventEpoch !== "string" ||
          typeof ack.through !== "number"
        ) {
          this.corruptRecords++;
          return;
        }
        const existing = this.acks.get(ack.installationId);
        // ack 幂等且不回退:重放旧 ack 不能把 cursor 拉回去。
        if (existing !== undefined && existing.through >= ack.through) return;
        this.acks.set(ack.installationId, ack as AckRecord);
        return;
      }
      case "generation": {
        const gen = data as Partial<GenerationRecord>;
        if (typeof gen.sourceId !== "string" || typeof gen.taskGenerationId !== "string") {
          this.corruptRecords++;
          return;
        }
        this.generations.set(gen.taskGenerationId, gen as GenerationRecord);
        return;
      }
      case "tombstone": {
        const stone = data as { sequence?: number };
        if (typeof stone.sequence === "number") {
          const event = this.events.get(stone.sequence);
          if (event !== undefined) {
            this.eventIdIndex.delete(event.eventId);
            this.events.delete(stone.sequence);
          }
          this.tombstones++;
        }
        return;
      }
      case "delivery":
        // 投递状态是易失的:重启后 LAN subscription 从空开始,
        // 客户端重连时按 cursor 重新对账,没必要 replay 旧的发送态。
        return;
    }
  }

  // -------------------------------------------------------------------------
  // 写入
  // -------------------------------------------------------------------------

  private openFd(): number {
    if (this.fd === undefined) {
      this.fd = fs.openSync(this.filePath, "a", 0o600);
    }
    return this.fd;
  }

  /// 单一串行 writer。append + fsync 都成功才返回 true;
  /// 任一失败都返回 false,调用方必须据此决定「不宣称 persisted」。
  private appendSync(kind: RecordKind, data: unknown): boolean {
    try {
      this.faultInjector?.("append");
      const fd = this.openFd();
      fs.writeFileSync(fd, wrap(kind, data));
      this.faultInjector?.("fsync");
      fs.fsyncSync(fd);
      this.degraded = false;
      return true;
    } catch (err) {
      this.writeFailures++;
      this.degraded = true;
      // 关掉 fd 让下次调用重开,避免 fd 处于未知状态后续全部失败。
      if (this.fd !== undefined) {
        try {
          fs.closeSync(this.fd);
        } catch {
          /* 已经坏了,忽略 */
        }
        this.fd = undefined;
      }
      console.error(`[notify] event store write failed (${kind}):`, err);
      return false;
    }
  }

  /// 追加事件。返回是否已 fsync 落盘 —— false 时事件进 pending,
  /// 调用方不得把它交给任何发送队列,也不得对客户端宣称 persisted。
  appendEvent(event: NotificationEventV1): boolean {
    const ok = this.appendSync("event", event);
    if (!ok) {
      if (this.pending.length >= this.maxPending) {
        // 背压:high 优先级仍保留,normal 直接丢并计数。
        const victim = this.pending.findIndex((item) => item.priority === "normal");
        if (victim >= 0) {
          this.pending.splice(victim, 1);
          this.droppedBackpressure++;
        } else {
          this.droppedBackpressure++;
          return false;
        }
      }
      this.pending.push(event);
      return false;
    }
    this.events.set(event.sequence, event);
    this.eventIdIndex.set(event.eventId, event.sequence);
    if (event.sequence > this.lastSequence) this.lastSequence = event.sequence;
    this.maybeCompact();
    return true;
  }

  /// 重试 pending。落盘恢复后(磁盘腾出空间、权限修好)把积压刷出去。
  flushPending(): number {
    let flushed = 0;
    while (this.pending.length > 0) {
      const event = this.pending[0];
      if (event === undefined) break;
      if (!this.appendSync("event", event)) break;
      this.pending.shift();
      this.events.set(event.sequence, event);
      this.eventIdIndex.set(event.eventId, event.sequence);
      if (event.sequence > this.lastSequence) this.lastSequence = event.sequence;
      flushed++;
    }
    if (flushed > 0) this.maybeCompact();
    return flushed;
  }

  nextSequence(): number {
    return this.lastSequence + 1;
  }

  // -------------------------------------------------------------------------
  // task generation:防 agent_end 与 agent_settled 生成两条完成通知
  // -------------------------------------------------------------------------

  beginGeneration(sourceId: string, taskGenerationId: string): boolean {
    const record: GenerationRecord = {
      sourceId,
      taskGenerationId,
      state: "in_flight",
      at: new Date(this.now()).toISOString(),
    };
    const ok = this.appendSync("generation", record);
    this.generations.set(taskGenerationId, record);
    return ok;
  }

  /// 标记完成。返回 false 表示这个 generation 已经完成过 ——
  /// 调用方据此跳过事件生成,这正是 end/settled 去重的地方。
  completeGeneration(taskGenerationId: string, eventId: string): boolean {
    const existing = this.generations.get(taskGenerationId);
    if (existing !== undefined && existing.state === "completed") return false;
    const record: GenerationRecord = {
      sourceId: existing?.sourceId ?? "",
      taskGenerationId,
      state: "completed",
      eventId,
      at: new Date(this.now()).toISOString(),
    };
    this.appendSync("generation", record);
    this.generations.set(taskGenerationId, record);
    return true;
  }

  /// 用户中断的收口:不生成事件,但要把代次落了,否则 journal 里的
  /// in_flight 记录会在 Bridge 重启后被 restoreGenerations 恢复,
  /// 下一个 agent_end 到来时被当成在飞任务补发一条过期的完成通知。
  cancelGeneration(taskGenerationId: string): boolean {
    const existing = this.generations.get(taskGenerationId);
    if (existing !== undefined && existing.state !== "in_flight") return false;
    const record: GenerationRecord = {
      sourceId: existing?.sourceId ?? "",
      taskGenerationId,
      state: "cancelled",
      at: new Date(this.now()).toISOString(),
    };
    this.appendSync("generation", record);
    this.generations.set(taskGenerationId, record);
    return true;
  }

  generationState(taskGenerationId: string): GenerationRecord | undefined {
    return this.generations.get(taskGenerationId);
  }

  /// 重启后仍处于 in_flight 的 generation。调用方据此恢复「任务还在跑」的判断,
  /// 之后的结束事件沿用原 generation 而不是新建一个。
  inFlightGenerations(): GenerationRecord[] {
    return [...this.generations.values()].filter((gen) => gen.state === "in_flight");
  }

  // -------------------------------------------------------------------------
  // cursor
  // -------------------------------------------------------------------------

  /// 记录 ack。只推进连续前缀由调用方保证;这里只做幂等与不回退。
  recordAck(installationId: string, eventEpoch: string, through: number): boolean {
    const existing = this.acks.get(installationId);
    if (existing !== undefined && existing.through >= through) return true;
    const record: AckRecord = {
      installationId,
      eventEpoch,
      through,
      at: new Date(this.now()).toISOString(),
    };
    const ok = this.appendSync("ack", record);
    if (ok) this.acks.set(installationId, record);
    return ok;
  }

  ackFor(installationId: string): AckRecord | undefined {
    return this.acks.get(installationId);
  }

  // -------------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------------

  /// 当前最高 sequence。subscribe 时先捕获它作为固定 tip,
  /// 分页期间新事件不得改变这个上界(否则客户端永远追不平)。
  tip(): number {
    return this.lastSequence;
  }

  /// 仍保留的最早 sequence。cursor 早于它就必须 rebase。
  oldestAvailable(): number {
    let oldest = Number.POSITIVE_INFINITY;
    for (const seq of this.events.keys()) if (seq < oldest) oldest = seq;
    return Number.isFinite(oldest) ? oldest : this.lastSequence;
  }

  /// 按 sequence 区间取事件(含两端)。返回按 sequence 升序。
  range(fromExclusive: number, through: number): NotificationEventV1[] {
    const out: NotificationEventV1[] = [];
    for (let seq = fromExclusive + 1; seq <= through; seq++) {
      const event = this.events.get(seq);
      if (event !== undefined) out.push(event);
    }
    return out;
  }

  hasEventId(eventId: string): boolean {
    return this.eventIdIndex.has(eventId);
  }

  eventBySequence(sequence: number): NotificationEventV1 | undefined {
    return this.events.get(sequence);
  }

  // -------------------------------------------------------------------------
  // TTL 与压缩
  // -------------------------------------------------------------------------

  /// 清掉过期事件。写 tombstone 而不是原地删,保持 append-only 语义。
  pruneExpired(): number {
    const now = this.now();
    let pruned = 0;
    for (const [seq, event] of [...this.events.entries()]) {
      const overRetention = now - Date.parse(event.createdAt) > this.retentionMs;
      if (!isExpired(event, now) && !overRetention) continue;
      this.appendSync("tombstone", { sequence: seq, eventId: event.eventId });
      this.eventIdIndex.delete(event.eventId);
      this.events.delete(seq);
      this.tombstones++;
      pruned++;
    }
    if (pruned > 0) this.maybeCompact();
    return pruned;
  }

  private currentBytes(): number {
    try {
      return fs.statSync(this.filePath).size;
    } catch {
      return 0;
    }
  }

  private maybeCompact(): void {
    const bytes = this.currentBytes();
    const total = this.events.size + this.tombstones;
    const ratio = total === 0 ? 0 : this.tombstones / total;
    if (
      bytes < this.maxBytes &&
      this.events.size < this.maxEvents &&
      ratio < this.tombstoneRatio
    ) {
      return;
    }
    this.compact();
  }

  /// 压缩:同目录临时文件 -> fsync -> 原子 rename -> fsync 目录。
  /// 任一步失败都保留原文件,宁可日志偏大也不能丢事件。
  compact(): boolean {
    const dir = path.dirname(this.filePath);
    const tmp = `${this.filePath}.compact-${process.pid}-${this.now()}`;
    // 超出条数上限时保留最新的,老事件已经没人会读了。
    const kept = [...this.events.values()]
      .sort((a, b) => a.sequence - b.sequence)
      .slice(-this.maxEvents);
    let lines = "";
    for (const event of kept) lines += wrap("event", event);
    for (const gen of this.generations.values()) lines += wrap("generation", gen);
    for (const ack of this.acks.values()) lines += wrap("ack", ack);
    try {
      this.faultInjector?.("compact-write");
      const fd = fs.openSync(tmp, "w", 0o600);
      try {
        fs.writeFileSync(fd, lines);
        fs.fsyncSync(fd);
      } finally {
        fs.closeSync(fd);
      }
      this.faultInjector?.("compact-rename");
      // 先关掉 append fd,否则 rename 后旧 fd 会继续写到已被替换的 inode。
      if (this.fd !== undefined) {
        fs.closeSync(this.fd);
        this.fd = undefined;
      }
      fs.renameSync(tmp, this.filePath);
      try {
        const dirFd = fs.openSync(dir, "r");
        try {
          fs.fsyncSync(dirFd);
        } finally {
          fs.closeSync(dirFd);
        }
      } catch {
        /* 平台不支持 fsync 目录;rename 本身原子 */
      }
      // 重建内存态,让 events 与文件内容一致。
      this.events.clear();
      this.eventIdIndex.clear();
      for (const event of kept) {
        this.events.set(event.sequence, event);
        this.eventIdIndex.set(event.eventId, event.sequence);
      }
      this.tombstones = 0;
      this.compactions++;
      return true;
    } catch (err) {
      this.writeFailures++;
      console.error("[notify] compaction failed; keeping original log:", err);
      try {
        fs.rmSync(tmp, { force: true });
      } catch {
        /* 清不掉临时文件不影响正确性 */
      }
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 诊断
  // -------------------------------------------------------------------------

  /// 是否处于降级状态(写失败/读失败)。诊断页必须展示它,
  /// 不能让「事件其实没落盘」表现为一切正常。
  isDegraded(): boolean {
    return this.degraded;
  }

  stats(): StoreStats {
    let oldestAge = 0;
    const now = this.now();
    for (const event of this.events.values()) {
      const age = now - Date.parse(event.createdAt);
      if (Number.isFinite(age) && age > oldestAge) oldestAge = age;
    }
    return {
      events: this.events.size,
      bytes: this.currentBytes(),
      tombstones: this.tombstones,
      oldestEventAgeMs: oldestAge,
      compactions: this.compactions,
      corruptRecords: this.corruptRecords,
      droppedBackpressure: this.droppedBackpressure,
      writeFailures: this.writeFailures,
      pending: this.pending.length,
    };
  }

  close(): void {
    if (this.fd !== undefined) {
      try {
        fs.closeSync(this.fd);
      } catch {
        /* 关闭失败无补救手段 */
      }
      this.fd = undefined;
    }
  }
}
