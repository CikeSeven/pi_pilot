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
  lastSeq: number;
  lease: OwnerLeaseManager;
}

export type RecordEventResult =
  | { ok: true; event: SequencedSourceEvent }
  | { ok: false; error: "missing" | "stale_epoch" | "sequence_gap" };

export type SourceSync =
  | { mode: "replay"; events: SequencedSourceEvent[] }
  | { mode: "snapshot"; snapshot: SourceSnapshot; events: SequencedSourceEvent[] }
  | { mode: "rpc"; baseSeq: number; events: SequencedSourceEvent[] };

export class SourceRegistry {
  readonly hubId = crypto.randomUUID();
  private readonly records = new Map<string, SourceRecord>();

  constructor(private readonly replayCapacity = 512) {}

  register(descriptor: SourceDescriptor, transport: SourceTransport): SourceDescriptor {
    const previous = this.records.get(descriptor.id);
    const sameEpoch = previous?.descriptor.epoch === descriptor.epoch;
    const record: SourceRecord = {
      descriptor: { ...descriptor, capabilities: [...descriptor.capabilities] },
      transport,
      snapshot: sameEpoch ? previous?.snapshot : undefined,
      events: sameEpoch ? [...(previous?.events ?? [])] : [],
      lastSeq: sameEpoch ? (previous?.lastSeq ?? 0) : 0,
      lease: sameEpoch ? previous!.lease : new OwnerLeaseManager(),
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
      record.events = [];
      record.lastSeq = 0;
      record.lease = new OwnerLeaseManager();
    }
    record.descriptor.connected = connected;
    if (!connected) record.lease = new OwnerLeaseManager();
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
      record.events = [];
      record.lastSeq = 0;
      record.lease = new OwnerLeaseManager();
    }
    record.snapshot = snapshot;
    record.lastSeq = Math.max(record.lastSeq, snapshot.baseSeq);
    record.events = record.events.filter(
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
      return { mode: "replay", events: record.events.filter((event) => event.seq > cursor.seq) };
    }
    if (record.snapshot) {
      return {
        mode: "snapshot",
        snapshot: record.snapshot,
        events: record.events.filter((event) => event.seq > record.snapshot!.baseSeq),
      };
    }
    return { mode: "rpc", baseSeq: record.lastSeq, events: [] };
  }

  acquire(sourceId: string, clientId: string, ttlMs: number): LeaseResult | undefined {
    return this.records.get(sourceId)?.lease.acquire(clientId, ttlMs);
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

  private pushEvent(record: SourceRecord, event: SequencedSourceEvent): void {
    record.events.push(event);
    if (record.events.length > this.replayCapacity) {
      record.events.splice(0, record.events.length - this.replayCapacity);
    }
  }

  private canReplay(record: SourceRecord, afterSeq: number): boolean {
    if (afterSeq > record.lastSeq) return false;
    const first = record.events[0]?.seq;
    return first === undefined ? afterSeq === record.lastSeq : afterSeq >= first - 1;
  }
}
