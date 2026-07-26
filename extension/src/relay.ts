import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RelayConfig } from "./config.js";
import { executeRemoteCommand, SAFE_REMOTE_COMMANDS, type RemoteCommand } from "./remote_commands.js";
import { cloneForWire, encodeForWire, MAX_SNAPSHOT_BYTES } from "./serialization.js";

type JsonObject = Record<string, unknown>;

const MAX_SOCKET_BUFFER = 2 * 1024 * 1024;
const MAX_CAPTURE_BYTES = 64 * 1024 * 1024;
const HEARTBEAT_MS = 10_000;
const MAX_COMMAND_QUEUE = 32;
const MAX_COMMAND_RESULTS = 256;

function serializeModel(model: ExtensionContext["model"]): JsonObject | null {
  if (!model) return null;
  return {
    id: model.id,
    name: model.name,
    provider: model.provider,
    api: model.api,
    reasoning: model.reasoning,
    input: model.input,
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    cost: model.cost,
  };
}

function sanitizeSourceId(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 128);
}

export class DesktopRelay {
  private socket: WebSocket | undefined;
  private ctx: ExtensionContext | undefined;
  private active = false;
  private registered = false;
  private epoch = crypto.randomUUID();
  private seq = 0;
  private reconnectAttempt = 0;
  private reconnectTimer: NodeJS.Timeout | undefined;
  private heartbeatTimer: NodeJS.Timeout | undefined;
  private messageTimer: NodeJS.Timeout | undefined;
  private toolTimer: NodeJS.Timeout | undefined;
  private pendingMessageUpdate: JsonObject | undefined;
  private pendingToolUpdates = new Map<string, JsonObject>();
  private inFlightMessage: JsonObject | undefined;
  private highestFence = 0;
  private ownerActive = false;
  private ownerFence = 0;
  private ownerExpiresAt = 0;
  private controlGeneration = 0;
  private commandDepth = 0;
  private commandChain: Promise<void> = Promise.resolve();
  private activeRequests = new Set<string>();
  private commandResults = new Map<string, JsonObject>();

  readonly sourceId = sanitizeSourceId(`${os.hostname()}:${process.pid}`);

  constructor(
    private readonly pi: ExtensionAPI,
    private readonly config: RelayConfig,
  ) {}

  start(ctx: ExtensionContext): void {
    this.stopInternal(false);
    this.ctx = ctx;
    this.active = true;
    this.setStatus("PiPilot: connecting");
    this.connect();
  }

  stop(ctx: ExtensionContext): void {
    if (ctx !== this.ctx) return;
    this.flushCoalesced();
    this.stopInternal(true);
  }

  dispose(): void {
    this.stopInternal(true);
  }

  emitBoundary(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.flushCoalesced();
    this.sendEvent(event);
  }

  emitEvent(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.sendEvent(event);
  }

  emitMessageUpdate<T extends { message?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx)) return;
    try {
      const cloned = cloneForWire(event) as JsonObject;
      this.pendingMessageUpdate = cloned;
      if (cloned.message && typeof cloned.message === "object") {
        this.inFlightMessage = cloned.message as JsonObject;
      }
    } catch {
      this.resnapshot("message update too large");
      return;
    }
    if (!this.messageTimer) {
      this.messageTimer = setTimeout(() => {
        this.messageTimer = undefined;
        const pending = this.pendingMessageUpdate;
        this.pendingMessageUpdate = undefined;
        if (pending) this.sendEvent(pending);
      }, 25);
      this.messageTimer.unref();
    }
  }

  emitMessageEnd(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.flushMessageUpdate();
    this.sendEvent(event);
    this.inFlightMessage = undefined;
  }

  emitToolUpdate<T extends { toolCallId?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx) || typeof event.toolCallId !== "string") return;
    try {
      this.pendingToolUpdates.set(event.toolCallId, cloneForWire(event) as JsonObject);
    } catch {
      this.resnapshot("tool update too large");
      return;
    }
    if (!this.toolTimer) {
      this.toolTimer = setTimeout(() => {
        this.toolTimer = undefined;
        this.flushToolUpdates();
      }, 100);
      this.toolTimer.unref();
    }
  }

  emitToolEnd<T extends { toolCallId?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx)) return;
    if (typeof event.toolCallId === "string") {
      const pending = this.pendingToolUpdates.get(event.toolCallId);
      if (pending) {
        this.pendingToolUpdates.delete(event.toolCallId);
        this.sendEvent(pending);
      }
    }
    this.sendEvent(event);
  }

  snapshot(ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.sendSnapshot("state changed");
  }

  private connect(): void {
    if (!this.active || this.socket) return;
    const socket = new WebSocket(this.config.url, { handshakeTimeout: 5_000 });
    this.socket = socket;

    socket.on("open", () => {
      if (this.socket !== socket || !this.active) return;
      this.reconnectAttempt = 0;
      this.registered = false;
      this.newEpoch();
      this.sendRegistration();
    });
    socket.on("message", (data) => this.handleHubMessage(data.toString()));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.registered = false;
      this.clearHeartbeat();
      if (this.active) {
        this.setStatus("PiPilot: reconnecting");
        this.scheduleReconnect();
      }
    });
    socket.on("error", () => socket.close());
  }

  private handleHubMessage(text: string): void {
    let msg: JsonObject;
    try {
      msg = JSON.parse(text) as JsonObject;
    } catch {
      return;
    }
    switch (msg.type) {
      case "desktop_registered":
        if (msg.epoch !== this.epoch) return;
        this.registered = true;
        this.setStatus("PiPilot: synced");
        this.startHeartbeat();
        this.sendSnapshot("registration barrier");
        return;

      case "desktop_status": {
        const selected = typeof msg.selectedClients === "number" ? msg.selectedClients : 0;
        const owner = msg.owner && typeof msg.owner === "object" ? (msg.owner as JsonObject) : {};
        const nextOwnerActive = owner.owned === true;
        const nextOwnerFence =
          nextOwnerActive && typeof owner.fence === "number" && Number.isSafeInteger(owner.fence)
            ? owner.fence
            : 0;
        const nextOwnerExpiresAt =
          nextOwnerActive &&
          typeof owner.expiresAt === "number" &&
          Number.isSafeInteger(owner.expiresAt)
            ? owner.expiresAt
            : 0;
        if (nextOwnerActive !== this.ownerActive || nextOwnerFence !== this.ownerFence) {
          this.controlGeneration++;
        }
        this.ownerActive = nextOwnerActive;
        this.ownerFence = nextOwnerFence;
        this.ownerExpiresAt = nextOwnerExpiresAt;
        this.highestFence = Math.max(this.highestFence, nextOwnerFence);
        this.setStatus(
          nextOwnerActive
            ? `PiPilot: controlled (${selected})`
            : `PiPilot: synced (${selected})`,
        );
        return;
      }

      case "desktop_resync_required":
        this.resnapshot(typeof msg.reason === "string" ? msg.reason : "hub requested resync");
        return;

      case "remote_command":
        this.queueRemoteCommand(msg);
        return;

      case "desktop_heartbeat_ack":
      case "desktop_ack":
      case "desktop_hello":
        return;
    }
  }

  private queueRemoteCommand(msg: JsonObject): void {
    const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
    if (!requestId) return;
    const cached = this.commandResults.get(requestId);
    if (cached) {
      this.sendFrame(cached);
      return;
    }
    if (this.activeRequests.has(requestId)) return;
    if (this.commandDepth >= MAX_COMMAND_QUEUE) {
      this.sendCommandResult(requestId, false, undefined, "desktop command queue is full");
      return;
    }
    if (msg.epoch !== this.epoch) {
      this.sendCommandResult(requestId, false, undefined, "stale desktop session epoch");
      return;
    }
    if (typeof msg.fence !== "number" || !Number.isSafeInteger(msg.fence)) {
      this.sendCommandResult(requestId, false, undefined, "missing fencing token");
      return;
    }
    if (msg.fence < this.highestFence) {
      this.sendCommandResult(requestId, false, undefined, "stale fencing token");
      return;
    }
    if (!this.hasActiveOwner(msg.fence)) {
      this.sendCommandResult(requestId, false, undefined, "owner lease is not active or has expired");
      return;
    }
    if (!msg.command || typeof msg.command !== "object") {
      this.sendCommandResult(requestId, false, undefined, "invalid command");
      return;
    }

    this.highestFence = Math.max(this.highestFence, msg.fence);
    this.activeRequests.add(requestId);
    this.commandDepth++;
    const command = cloneForWire(msg.command) as RemoteCommand;
    const queuedEpoch = this.epoch;
    const queuedFence = msg.fence;
    const queuedGeneration = this.controlGeneration;
    this.commandChain = this.commandChain
      .then(async () => {
        const ctx = this.ctx;
        if (!this.active || !ctx) throw new Error("desktop runtime is shutting down");
        if (
          queuedEpoch !== this.epoch ||
          queuedGeneration !== this.controlGeneration ||
          !this.hasActiveOwner(queuedFence) ||
          queuedFence < this.highestFence
        ) {
          throw new Error("queued command has a stale owner lease");
        }
        return executeRemoteCommand(command, { pi: this.pi, ctx });
      })
      .then(
        (data) => this.sendCommandResult(requestId, true, data),
        (error) =>
          this.sendCommandResult(
            requestId,
            false,
            undefined,
            error instanceof Error ? error.message : String(error),
          ),
      )
      .finally(() => {
        this.activeRequests.delete(requestId);
        this.commandDepth--;
      });
  }

  private sendCommandResult(
    requestId: string,
    success: boolean,
    data?: unknown,
    error?: string,
  ): void {
    const result: JsonObject = {
      type: "remote_result",
      requestId,
      success,
      ...(data !== undefined ? { data } : {}),
      ...(error ? { error } : {}),
    };
    this.commandResults.set(requestId, result);
    while (this.commandResults.size > MAX_COMMAND_RESULTS) {
      const oldest = this.commandResults.keys().next().value as string | undefined;
      if (!oldest) break;
      this.commandResults.delete(oldest);
    }
    this.sendFrame(result);
  }

  private sendRegistration(): void {
    const ctx = this.liveCtx();
    if (!ctx) return;
    const snapshot = this.captureSnapshot();
    if (!snapshot) return;
    this.sendFrame(
      {
        type: "desktop_register",
        source: {
          sourceId: this.sourceId,
          label:
            this.config.label ?? `${path.basename(ctx.cwd) || ctx.cwd} · PID ${process.pid}`,
          cwd: ctx.cwd,
          sessionId: ctx.sessionManager.getSessionId(),
          sessionFile: ctx.sessionManager.getSessionFile(),
          sessionName: ctx.sessionManager.getSessionName(),
          capabilities: [...SAFE_REMOTE_COMMANDS],
        },
        snapshot,
      },
      MAX_SNAPSHOT_BYTES,
    );
  }

  private sendSnapshot(reason: string): void {
    if (!this.registered) return;
    const snapshot = this.captureSnapshot();
    if (!snapshot) return;
    this.sendFrame(
      {
        type: "desktop_snapshot",
        reason,
        snapshot,
      },
      MAX_SNAPSHOT_BYTES,
    );
  }

  private captureSnapshot(): JsonObject | undefined {
    const ctx = this.liveCtx();
    if (!ctx) return undefined;
    let entries = cloneForWire(
      ctx.sessionManager.getBranch(),
      MAX_CAPTURE_BYTES,
    ) as unknown as JsonObject[];
    const models = ctx.modelRegistry.getAvailable().map((model) => serializeModel(model));
    const contextUsage = ctx.getContextUsage();
    const state: JsonObject = {
      model: serializeModel(ctx.model),
      thinkingLevel: this.pi.getThinkingLevel(),
      isStreaming: !ctx.isIdle(),
      isCompacting: false,
      steeringMode: "one-at-a-time",
      followUpMode: "one-at-a-time",
      sessionFile: ctx.sessionManager.getSessionFile() ?? null,
      sessionId: ctx.sessionManager.getSessionId(),
      sessionName: ctx.sessionManager.getSessionName() ?? null,
      cwd: ctx.cwd,
      autoCompactionEnabled: false,
      messageCount: entries.length,
      pendingMessageCount: ctx.hasPendingMessages() ? 1 : 0,
      contextUsage: contextUsage ?? null,
    };
    const makeSnapshot = (): JsonObject => ({
      epoch: this.epoch,
      baseSeq: this.seq,
      capturedAt: Date.now(),
      state,
      entries,
      leafId: ctx.sessionManager.getLeafId(),
      models,
      thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
      ...(this.inFlightMessage ? { inFlightMessage: this.inFlightMessage } : {}),
    });

    let snapshot = makeSnapshot();
    while (entries.length > 1) {
      try {
        encodeForWire(snapshot, MAX_SNAPSHOT_BYTES);
        return snapshot;
      } catch {
        const removeCount = Math.max(1, Math.floor(entries.length / 4));
        entries = entries.slice(removeCount);
        state.snapshotTruncated = true;
        state.messageCount = entries.length;
        snapshot = makeSnapshot();
      }
    }
    encodeForWire(snapshot, MAX_SNAPSHOT_BYTES);
    return snapshot;
  }

  private sendEvent(event: unknown): void {
    if (!this.registered) return;
    try {
      const cloned = cloneForWire(event) as JsonObject;
      this.sendFrame({
        type: "desktop_event",
        epoch: this.epoch,
        seq: ++this.seq,
        event: cloned,
      });
    } catch {
      this.resnapshot("event serialization failed");
    }
  }

  private sendFrame(frame: JsonObject, maxBytes?: number): boolean {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    if (socket.bufferedAmount > MAX_SOCKET_BUFFER) {
      socket.close(1013, "relay backpressure");
      return false;
    }
    try {
      socket.send(encodeForWire(frame, maxBytes));
      return true;
    } catch {
      socket.close(1011, "relay serialization failure");
      return false;
    }
  }

  private resnapshot(_reason: string): void {
    if (!this.active || !this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.newEpoch();
    this.registered = true;
    this.sendSnapshot("epoch reset");
  }

  private newEpoch(): void {
    this.cancelCoalesced();
    this.epoch = crypto.randomUUID();
    this.seq = 0;
    this.controlGeneration++;
    this.ownerActive = false;
    this.ownerFence = 0;
    this.ownerExpiresAt = 0;
    this.commandResults.clear();
    this.highestFence = 0;
  }

  private scheduleReconnect(): void {
    if (!this.active || this.reconnectTimer) return;
    const base = Math.min(
      this.config.reconnectMaxMs,
      this.config.reconnectMinMs * 2 ** this.reconnectAttempt++,
    );
    const delay = Math.round(base * (0.8 + Math.random() * 0.4));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
    this.reconnectTimer.unref();
  }

  private startHeartbeat(): void {
    this.clearHeartbeat();
    this.heartbeatTimer = setInterval(
      () => this.sendFrame({ type: "desktop_heartbeat", t: Date.now() }),
      HEARTBEAT_MS,
    );
    this.heartbeatTimer.unref();
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
  }

  private flushMessageUpdate(): void {
    if (this.messageTimer) clearTimeout(this.messageTimer);
    this.messageTimer = undefined;
    const pending = this.pendingMessageUpdate;
    this.pendingMessageUpdate = undefined;
    if (pending) this.sendEvent(pending);
  }

  private flushToolUpdates(): void {
    if (this.toolTimer) clearTimeout(this.toolTimer);
    this.toolTimer = undefined;
    for (const event of this.pendingToolUpdates.values()) this.sendEvent(event);
    this.pendingToolUpdates.clear();
  }

  private flushCoalesced(): void {
    this.flushMessageUpdate();
    this.flushToolUpdates();
  }

  private cancelCoalesced(): void {
    if (this.messageTimer) clearTimeout(this.messageTimer);
    if (this.toolTimer) clearTimeout(this.toolTimer);
    this.messageTimer = undefined;
    this.toolTimer = undefined;
    this.pendingMessageUpdate = undefined;
    this.pendingToolUpdates.clear();
  }

  private stopInternal(clearStatus: boolean): void {
    this.active = false;
    this.registered = false;
    this.controlGeneration++;
    this.ownerActive = false;
    this.ownerFence = 0;
    this.ownerExpiresAt = 0;
    this.cancelCoalesced();
    this.clearHeartbeat();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    const socket = this.socket;
    this.socket = undefined;
    socket?.close(1000, "desktop runtime stopped");
    if (clearStatus) this.setStatus(undefined);
    this.ctx = undefined;
  }

  private setStatus(text: string | undefined): void {
    // The captured ctx goes stale after session replacement/reload; accessing
    // any of its getters (including ctx.ui) then throws. Async socket/timer
    // callbacks can run after that, so swallow the stale-ctx error here.
    try {
      this.ctx?.ui.setStatus("pipilot-sync", text);
    } catch {
      // stale ctx after session replacement; nothing to update
    }
  }

  private liveCtx(): ExtensionContext | undefined {
    const ctx = this.ctx;
    if (!ctx) return undefined;
    try {
      void ctx.cwd; // any getter throws when the ctx is stale
      return ctx;
    } catch {
      return undefined;
    }
  }

  private hasActiveOwner(fence: number): boolean {
    return (
      this.ownerActive &&
      this.ownerFence === fence &&
      this.ownerExpiresAt > Date.now()
    );
  }

  private isCurrent(ctx: ExtensionContext): boolean {
    return this.active && this.ctx === ctx;
  }
}
