import crypto from "node:crypto";
import { OwnerLeaseManager, type LeaseResult, type PublicOwnerState } from "./owner_lease.js";
import type { HubCursor, JsonObject } from "./hub_protocol.js";

export type SourceKind = "headless" | "desktop";

export interface SourceDescriptor {
  id: string;
  kind: SourceKind;
  label: string;
  connected: boolean;
  epoch: string;
  cwd?: string;
  sessionId?: string;
  sessionFile?: string;
  sessionName?: string;
  capabilities: string[];
}

export interface SourceSnapshot {
  epoch: string;
  baseSeq: number;
  capturedAt: number;
  state: JsonObject;
  entries: JsonObject[];
  leafId: string | null;
  models?: JsonObject[];
  thinkingLevels?: string[];
  inFlightMessage?: JsonObject;
  /** 桌面扩展快照透传字段:会话统计(pi SessionStats 形状)。 */
  stats?: JsonObject;
  /** 桌面扩展快照透传字段:可用命令列表。 */
  commands?: JsonObject[];
  /** 桌面扩展快照透传字段:压缩会话树。 */
  treeSummary?: JsonObject[];
}

export interface SequencedSourceEvent {
  sourceId: string;
  sourceEpoch: string;
  seq: number;
  payload: JsonObject;
}

export interface SourceTransport {
  send(message: JsonObject): boolean;
}

interface SourceRecord {
  descriptor: SourceDescriptor;
  transport: SourceTransport;
  snapshot?: SourceSnapshot;
  events: SequencedSourceEvent[];
  /** 与 events 平行的字节数组,用于字节预算裁剪。 */
  sizes: number[];
  bytes: number;
  lastSeq: number;
  lease: OwnerLeaseManager;
}

export type RecordEventResult =
  | { ok: true; event: SequencedSourceEvent }
  | { ok: false; error: "missing" | "stale_epoch" | "sequence_gap" };

/// `continuous` 表示 snapshot 与随后的事件是否首尾相接。
/// 不连续 = 重放环已经把 baseSeq 之后的事件挤掉了,客户端照单全收会永久错位。
export type SourceSync =
  | { mode: "replay"; events: SequencedSourceEvent[]; continuous: true }
  | {
      mode: "snapshot";
      snapshot: SourceSnapshot;
      events: SequencedSourceEvent[];
      continuous: boolean;
    }
  | { mode: "rpc"; baseSeq: number; events: SequencedSourceEvent[]; continuous: true };

export class SourceRegistry {
  readonly hubId = crypto.randomUUID();
  private readonly records = new Map<string, SourceRecord>();

  constructor(
    private readonly replayCapacity = 1024,
    private readonly replayByteBudget = 16 * 1024 * 1024,
  ) {}

  register(descriptor: SourceDescriptor, transport: SourceTransport): SourceDescriptor {
    const previous = this.records.get(descriptor.id);
    const sameEpoch = previous?.descriptor.epoch === descriptor.epoch;
    const record: SourceRecord = {
      descriptor: { ...descriptor, capabilities: [...descriptor.capabilities] },
      transport,
      snapshot: sameEpoch ? previous?.snapshot : undefined,
      events: sameEpoch ? [...(previous?.events ?? [])] : [],
      sizes: sameEpoch ? [...(previous?.sizes ?? [])] : [],
      bytes: sameEpoch ? (previous?.bytes ?? 0) : 0,
      lastSeq: sameEpoch ? (previous?.lastSeq ?? 0) : 0,
      // 换 epoch 只是"事件流重来了",不代表"谁在驱动"变了。
      // 沿用同一个 lease manager:fence 保持严格递增(旧持有者照样被作废),
      // 而正在驱动的客户端不会因为一次 fork / 进程重启就被踢掉。
      lease: previous?.lease ?? new OwnerLeaseManager(),
    };
    this.records.set(descriptor.id, record);
    return this.describe(descriptor.id)!;
  }

  remove(sourceId: string): boolean {
    return this.records.delete(sourceId);
  }

  get(sourceId: string): SourceDescriptor | undefined {
    return this.describe(sourceId);
  }

  transport(sourceId: string): SourceTransport | undefined {
    return this.records.get(sourceId)?.transport;
  }

  list(clientId?: string): Array<SourceDescriptor & { owner: PublicOwnerState; ownedByYou: boolean }> {
    return [...this.records.keys()]
      .map((id) => this.describeForClient(id, clientId)!)
      .sort((a, b) => {
        if (a.kind !== b.kind) return a.kind === "desktop" ? -1 : 1;
        return a.label.localeCompare(b.label);
      });
  }

  setConnected(sourceId: string, connected: boolean, epoch?: string): SourceDescriptor | undefined {
    const record = this.records.get(sourceId);
    if (!record) return undefined;
    if (epoch && epoch !== record.descriptor.epoch) {
      record.descriptor.epoch = epoch;
      record.snapshot = undefined;
      this.clearEvents(record);
      record.lastSeq = 0;
    }
    record.descriptor.connected = connected;
    return this.describe(sourceId);
  }

  updateMetadata(sourceId: string, patch: Partial<Omit<SourceDescriptor, "id" | "kind">>): void {
    const record = this.records.get(sourceId);
    if (!record) return;
    record.descriptor = {
      ...record.descriptor,
      ...patch,
      capabilities: patch.capabilities
        ? [...patch.capabilities]
        : record.descriptor.capabilities,
    };
  }

  setSnapshot(sourceId: string, snapshot: SourceSnapshot): boolean {
    const record = this.records.get(sourceId);
    if (!record || snapshot.baseSeq < 0) return false;
    const sameEpoch = snapshot.epoch === record.descriptor.epoch;
    if (!sameEpoch) {
      record.descriptor.epoch = snapshot.epoch;
      this.clearEvents(record);
      record.lastSeq = 0;
    }
    record.snapshot = snapshot;
    record.lastSeq = Math.max(record.lastSeq, snapshot.baseSeq);
    this.filterEvents(
      record,
      (event) => event.sourceEpoch === snapshot.epoch && event.seq > snapshot.baseSeq,
    );
    const state = snapshot.state;
    this.updateMetadata(sourceId, {
      cwd: typeof state.cwd === "string" ? state.cwd : record.descriptor.cwd,
      sessionId:
        typeof state.sessionId === "string" ? state.sessionId : record.descriptor.sessionId,
      sessionFile:
        typeof state.sessionFile === "string" ? state.sessionFile : record.descriptor.sessionFile,
      sessionName:
        typeof state.sessionName === "string" ? state.sessionName : record.descriptor.sessionName,
    });
    return true;
  }

  getSnapshot(sourceId: string): SourceSnapshot | undefined {
    return this.records.get(sourceId)?.snapshot;
  }

  recordLocalEvent(sourceId: string, payload: JsonObject): RecordEventResult {
    const record = this.records.get(sourceId);
    if (!record) return { ok: false, error: "missing" };
    const event: SequencedSourceEvent = {
      sourceId,
      sourceEpoch: record.descriptor.epoch,
      seq: ++record.lastSeq,
      payload,
    };
    this.pushEvent(record, event);
    return { ok: true, event };
  }

  recordDesktopEvent(
    sourceId: string,
    sourceEpoch: string,
    seq: number,
    payload: JsonObject,
  ): RecordEventResult {
    const record = this.records.get(sourceId);
    if (!record) return { ok: false, error: "missing" };
    if (record.descriptor.epoch !== sourceEpoch) return { ok: false, error: "stale_epoch" };
    if (!Number.isSafeInteger(seq) || seq !== record.lastSeq + 1) {
      return { ok: false, error: "sequence_gap" };
    }
    const event: SequencedSourceEvent = { sourceId, sourceEpoch, seq, payload };
    record.lastSeq = seq;
    this.pushEvent(record, event);
    return { ok: true, event };
  }

  sync(sourceId: string, cursor?: HubCursor): SourceSync | undefined {
    const record = this.records.get(sourceId);
    if (!record) return undefined;
    const matchingCursor =
      cursor?.hubId === this.hubId &&
      cursor.sourceId === sourceId &&
      cursor.sourceEpoch === record.descriptor.epoch;
    if (matchingCursor && this.canReplay(record, cursor.seq)) {
      return {
        mode: "replay",
        events: record.events.filter((event) => event.seq > cursor.seq),
        continuous: true,
      };
    }
    if (record.snapshot) {
      const snapshot = record.snapshot;
      return {
        mode: "snapshot",
        snapshot,
        events: record.events.filter((event) => event.seq > snapshot.baseSeq),
        continuous: this.isSnapshotContinuous(record),
      };
    }
    return { mode: "rpc", baseSeq: record.lastSeq, events: [], continuous: true };
  }

  /** hub 用来判断是否需要向桌面索要新快照。 */
  snapshotIsContinuous(sourceId: string): boolean {
    const record = this.records.get(sourceId);
    return record ? this.isSnapshotContinuous(record) : false;
  }

  acquire(
    sourceId: string,
    clientId: string,
    ttlMs: number,
    opts?: { force?: boolean },
  ): LeaseResult | undefined {
    return this.records.get(sourceId)?.lease.acquire(clientId, ttlMs, opts);
  }

  renew(
    sourceId: string,
    clientId: string,
    leaseId: string,
    fence: number,
    ttlMs: number,
  ): LeaseResult | undefined {
    return this.records.get(sourceId)?.lease.renew(clientId, leaseId, fence, ttlMs);
  }

  validate(
    sourceId: string,
    clientId: string,
    leaseId: unknown,
    fence: unknown,
  ): LeaseResult | undefined {
    return this.records.get(sourceId)?.lease.validate(clientId, leaseId, fence);
  }

  release(sourceId: string, clientId: string, leaseId?: string, fence?: number): boolean {
    return this.records.get(sourceId)?.lease.release(clientId, leaseId, fence) ?? false;
  }

  releaseClient(clientId: string): string[] {
    const released: string[] = [];
    for (const [sourceId, record] of this.records) {
      if (record.lease.releaseClient(clientId)) released.push(sourceId);
    }
    return released;
  }

  expireLeases(): string[] {
    const expired: string[] = [];
    for (const [sourceId, record] of this.records) {
      if (record.lease.expire()) expired.push(sourceId);
    }
    return expired;
  }

  private describe(sourceId: string): SourceDescriptor | undefined {
    const descriptor = this.records.get(sourceId)?.descriptor;
    return descriptor ? { ...descriptor, capabilities: [...descriptor.capabilities] } : undefined;
  }

  private describeForClient(
    sourceId: string,
    clientId?: string,
  ): (SourceDescriptor & { owner: PublicOwnerState; ownedByYou: boolean }) | undefined {
    const record = this.records.get(sourceId);
    if (!record) return undefined;
    return {
      ...record.descriptor,
      capabilities: [...record.descriptor.capabilities],
      owner: record.lease.publicState(),
      ownedByYou: clientId ? record.lease.isOwnedBy(clientId) : false,
    };
  }

  /// 快照与事件流是否首尾相接:snapshot 之后的第一个事件必须正好是 baseSeq+1,
  /// 且最后一个必须等于 lastSeq。这就是 canReplay 一直缺席于快照分支的那道校验。
  private isSnapshotContinuous(record: SourceRecord): boolean {
    const snapshot = record.snapshot;
    if (!snapshot) return false;
    if (snapshot.epoch !== record.descriptor.epoch) return false;
    const events = record.events.filter((event) => event.seq > snapshot.baseSeq);
    if (events.length === 0) return record.lastSeq === snapshot.baseSeq;
    return (
      events[0]!.seq === snapshot.baseSeq + 1 &&
      events[events.length - 1]!.seq === record.lastSeq
    );
  }

  private clearEvents(record: SourceRecord): void {
    record.events = [];
    record.sizes = [];
    record.bytes = 0;
  }

  /** 保留 events/sizes/bytes 三者一致的过滤。 */
  private filterEvents(
    record: SourceRecord,
    keep: (event: SequencedSourceEvent) => boolean,
  ): void {
    const events: SequencedSourceEvent[] = [];
    const sizes: number[] = [];
    let bytes = 0;
    for (const [index, event] of record.events.entries()) {
      if (!keep(event)) continue;
      const size = record.sizes[index] ?? 0;
      events.push(event);
      sizes.push(size);
      bytes += size;
    }
    record.events = events;
    record.sizes = sizes;
    record.bytes = bytes;
  }

  private pushEvent(record: SourceRecord, event: SequencedSourceEvent): void {
    const bytes = JSON.stringify(event.payload).length;
    record.events.push(event);
    record.sizes.push(bytes);
    record.bytes += bytes;
    // 条数上限 + 字节预算双限:message_update 携带完整消息,只按条数裁剪会吃掉几十 MB。
    while (
      record.events.length > this.replayCapacity ||
      (record.bytes > this.replayByteBudget && record.events.length > 1)
    ) {
      record.bytes -= record.sizes.shift() ?? 0;
      record.events.shift();
    }
  }

  private canReplay(record: SourceRecord, afterSeq: number): boolean {
    if (afterSeq > record.lastSeq) return false;
    const first = record.events[0]?.seq;
    return first === undefined ? afterSeq === record.lastSeq : afterSeq >= first - 1;
  }
}
