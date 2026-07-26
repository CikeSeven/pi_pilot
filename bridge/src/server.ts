import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { WebSocket, WebSocketServer } from "ws";
import {
  buildPiArgs,
  buildPiArgsForSessionPath,
  lanUrls,
  loadConfig,
  writeFileConfig,
} from "./config.js";
import {
  HUB_PROTOCOL_VERSION,
  MAX_BUFFERED_SOCKET_BYTES,
  MAX_CLIENT_MESSAGE_BYTES,
  MAX_DESKTOP_MESSAGE_BYTES,
  clampLeaseTtl,
  isDesktopMutationCommand,
  isReadOnlySourceCommand,
  parseCursor,
  withoutHubMetadata,
  type BridgeMessage,
  type JsonObject,
} from "./hub_protocol.js";
import { PiProcess } from "./pi_process.js";
import { quiesceSourceForHandoff } from "./source_handoff.js";
import { listDirs, listSessions, SESSIONS_ROOT } from "./sessions.js";
import {
  SourceRegistry,
  type SequencedSourceEvent,
  type SourceDescriptor,
  type SourceSnapshot,
} from "./source_registry.js";

const config = loadConfig();
const pi = new PiProcess(config.piArgs, config.piCwd);
const sources = new SourceRegistry(config.replayCapacity);
const HEADLESS_SOURCE_ID = config.headlessSourceId;

let currentCwd = config.piCwd;
let currentSessionId = config.sessionId;
let headlessEnabled = config.headlessAutoStart;
let shuttingDown = false;

interface MobileClient {
  clientId: string;
  ws: WebSocket;
  selectedSourceId?: string;
}

interface DesktopClient {
  ws: WebSocket;
  sourceId?: string;
  registering?: boolean;
}

interface PendingRequest {
  clientId: string;
  ws: WebSocket;
  sourceId: string;
  command: string;
  originalId?: string;
  timeout: NodeJS.Timeout;
}

const mobileClients = new Map<WebSocket, MobileClient>();
const desktopClients = new Set<DesktopClient>();
const desktopBySource = new Map<string, DesktopClient>();
const pending = new Map<string, PendingRequest>();

sources.register(
  {
    id: HEADLESS_SOURCE_ID,
    kind: "headless",
    label: config.headlessSourceName,
    connected: false,
    epoch: crypto.randomUUID(),
    cwd: currentCwd,
    sessionId: currentSessionId,
    capabilities: ["pi-rpc", "sessions", "directories"],
  },
  { send: (message) => pi.send(message) },
);

function sendRaw(ws: WebSocket, data: string): boolean {
  if (ws.readyState !== WebSocket.OPEN) return false;
  if (ws.bufferedAmount > MAX_BUFFERED_SOCKET_BYTES) {
    ws.close(1013, "client is too slow");
    return false;
  }
  ws.send(data);
  return true;
}

function sendObject(ws: WebSocket, value: unknown): boolean {
  return sendRaw(ws, JSON.stringify(value));
}

function tokenMatches(candidate: string | null, expected: string): boolean {
  if (!candidate) return false;
  const left = Buffer.from(candidate);
  const right = Buffer.from(expected);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function respond(
  ws: WebSocket,
  msg: BridgeMessage,
  success: boolean,
  data?: unknown,
  error?: string,
): void {
  sendObject(ws, {
    type: "response",
    command: msg.type,
    ...(typeof msg.id === "string" ? { id: msg.id } : {}),
    success,
    ...(data !== undefined ? { data } : {}),
    ...(error !== undefined ? { error } : {}),
  });
}

function eventFrame(event: SequencedSourceEvent): JsonObject {
  const { _hub: _ignored, ...payload } = event.payload;
  return {
    ...payload,
    _hub: {
      hubId: sources.hubId,
      sourceId: event.sourceId,
      sourceEpoch: event.sourceEpoch,
      seq: event.seq,
    },
  };
}

function broadcastSourceEvent(event: SequencedSourceEvent): void {
  const frame = eventFrame(event);
  for (const client of mobileClients.values()) {
    if (client.selectedSourceId === event.sourceId) sendObject(client.ws, frame);
  }
}

function broadcastHubEvent(type: string, data: JsonObject = {}): void {
  for (const client of mobileClients.values()) sendObject(client.ws, { type, ...data });
}

function sourceForClient(client: MobileClient, sourceId: string) {
  return sources.list(client.clientId).find((source) => source.id === sourceId);
}

function notifySourcesChanged(): void {
  for (const client of mobileClients.values()) {
    sendObject(client.ws, {
      type: "hub_sources_changed",
      hubId: sources.hubId,
      sources: sources.list(client.clientId),
    });
  }
  for (const source of sources.list()) pushDesktopStatus(source.id);
}

function notifyOwnerChanged(sourceId: string): void {
  for (const client of mobileClients.values()) {
    sendObject(client.ws, {
      type: "hub_owner_changed",
      sourceId,
      source: sourceForClient(client, sourceId),
    });
  }
  pushDesktopStatus(sourceId);
}

function pushDesktopStatus(sourceId: string): void {
  const desktop = desktopBySource.get(sourceId);
  if (!desktop) return;
  const source = sources.list().find((item) => item.id === sourceId);
  if (!source) return;
  const selectedClients = [...mobileClients.values()].filter(
    (client) => client.selectedSourceId === sourceId,
  ).length;
  sendObject(desktop.ws, {
    type: "desktop_status",
    selectedClients,
    owner: source.owner,
  });
}

function failPendingForSource(sourceId: string, error: string): void {
  for (const [requestId, request] of pending) {
    if (request.sourceId !== sourceId) continue;
    clearTimeout(request.timeout);
    pending.delete(requestId);
    sendObject(request.ws, {
      type: "response",
      command: request.command,
      ...(request.originalId ? { id: request.originalId } : {}),
      success: false,
      error,
    });
  }
}

function resolvePending(requestId: string, result: JsonObject): boolean {
  const request = pending.get(requestId);
  if (!request) return false;
  pending.delete(requestId);
  clearTimeout(request.timeout);
  sendObject(request.ws, {
    type: "response",
    command: request.command,
    ...(request.originalId ? { id: request.originalId } : {}),
    success: result.success === true,
    ...(result.data !== undefined ? { data: result.data } : {}),
    ...(typeof result.error === "string" ? { error: result.error } : {}),
  });
  return true;
}

function forwardSourceCommand(
  client: MobileClient,
  source: SourceDescriptor,
  msg: BridgeMessage,
): void {
  const command = withoutHubMetadata(msg);
  delete command.id;
  const requestId = `hub:${crypto.randomUUID()}`;
  const timeout = setTimeout(() => {
    const request = pending.get(requestId);
    if (!request) return;
    pending.delete(requestId);
    respond(request.ws, msg, false, undefined, "source command timed out");
  }, 30_000);
  timeout.unref();
  pending.set(requestId, {
    clientId: client.clientId,
    ws: client.ws,
    sourceId: source.id,
    command: msg.type!,
    originalId: msg.id,
    timeout,
  });

  const transport = sources.transport(source.id);
  const sent =
    source.kind === "desktop"
      ? transport?.send({
          type: "remote_command",
          requestId,
          epoch: source.epoch,
          fence: msg._hub?.fence,
          command,
        })
      : transport?.send({ ...command, id: requestId });
  if (!sent) {
    clearTimeout(timeout);
    pending.delete(requestId);
    respond(client.ws, msg, false, undefined, "source is not available");
  }
}

function handleDesktopRead(client: MobileClient, source: SourceDescriptor, msg: BridgeMessage): void {
  const snapshot = sources.getSnapshot(source.id);
  if (!snapshot) {
    respond(client.ws, msg, false, undefined, "desktop snapshot is not available yet");
    return;
  }
  switch (msg.type) {
    case "get_state":
      respond(client.ws, msg, true, snapshot.state);
      return;
    case "get_entries": {
      let entries = snapshot.entries;
      if (typeof msg.since === "string") {
        const index = entries.findIndex((entry) => entry.id === msg.since);
        if (index < 0) {
          respond(client.ws, msg, false, undefined, "entry cursor not found in desktop snapshot");
          return;
        }
        entries = entries.slice(index + 1);
      }
      respond(client.ws, msg, true, { entries, leafId: snapshot.leafId });
      return;
    }
    case "get_available_models":
      respond(client.ws, msg, true, { models: snapshot.models ?? [] });
      return;
    case "get_available_thinking_levels":
      respond(client.ws, msg, true, {
        levels: snapshot.thinkingLevels ?? ["off", "minimal", "low", "medium", "high"],
      });
      return;
    default:
      respond(client.ws, msg, false, undefined, `${msg.type} is not available for desktop sources`);
  }
}

function requireSelectedSource(client: MobileClient, msg: BridgeMessage): SourceDescriptor | undefined {
  if (!client.selectedSourceId) {
    respond(client.ws, msg, false, undefined, "select a source first");
    return undefined;
  }
  const source = sources.get(client.selectedSourceId);
  if (!source?.connected) {
    respond(client.ws, msg, false, undefined, "selected source is offline");
    return undefined;
  }
  return source;
}

function requireLease(
  client: MobileClient,
  sourceId: string,
  msg: BridgeMessage,
): { fence: number } | undefined {
  const result = sources.validate(sourceId, client.clientId, msg._hub?.leaseId, msg._hub?.fence);
  if (!result?.ok) {
    respond(client.ws, msg, false, undefined, result?.error ?? "source not found");
    return undefined;
  }
  return { fence: result.lease.fence };
}

function handleSourceCommand(client: MobileClient, msg: BridgeMessage): void {
  const source = requireSelectedSource(client, msg);
  if (!source || typeof msg.type !== "string") return;

  if (isReadOnlySourceCommand(msg.type)) {
    if (source.kind === "desktop") handleDesktopRead(client, source, msg);
    else forwardSourceCommand(client, source, msg);
    return;
  }

  if (!requireLease(client, source.id, msg)) return;
  if (source.kind === "desktop" && !isDesktopMutationCommand(msg.type)) {
    respond(client.ws, msg, false, undefined, `${msg.type} is not supported by the desktop relay`);
    return;
  }
  if (source.kind === "desktop" && !source.capabilities.includes(msg.type)) {
    respond(client.ws, msg, false, undefined, `desktop source does not advertise ${msg.type}`);
    return;
  }
  forwardSourceCommand(client, source, msg);
}

async function handleHubCommand(client: MobileClient, msg: BridgeMessage): Promise<void> {
  try {
    switch (msg.type) {
      case "hub_list_sources":
        respond(client.ws, msg, true, { hubId: sources.hubId, sources: sources.list(client.clientId) });
        return;

      case "hub_select_source": {
        const sourceId = typeof msg.sourceId === "string" ? msg.sourceId : "";
        const source = sources.get(sourceId);
        if (!source || (!source.connected && source.kind !== "headless")) {
          respond(client.ws, msg, false, undefined, "source is missing or offline");
          return;
        }
        const previous = client.selectedSourceId;
        client.selectedSourceId = sourceId;
        respond(client.ws, msg, true, {
          hubId: sources.hubId,
          source: sourceForClient(client, sourceId),
        });
        if (previous) pushDesktopStatus(previous);
        pushDesktopStatus(sourceId);
        return;
      }

      case "hub_sync": {
        const source = requireSelectedSource(client, msg);
        if (!source) return;
        const sync = sources.sync(source.id, parseCursor(msg.cursor));
        if (!sync) {
          respond(client.ws, msg, false, undefined, "source not found");
          return;
        }
        respond(client.ws, msg, true, {
          hubId: sources.hubId,
          sourceId: source.id,
          sourceEpoch: source.epoch,
          mode: sync.mode,
          ...(sync.mode === "snapshot" ? { snapshot: sync.snapshot } : {}),
          ...(sync.mode === "rpc" ? { baseSeq: sync.baseSeq } : {}),
          events: sync.events.map(eventFrame),
        });
        return;
      }

      case "hub_acquire_owner": {
        const sourceId = client.selectedSourceId;
        const source = sourceId ? sources.get(sourceId) : undefined;
        if (!source) {
          respond(client.ws, msg, false, undefined, "select a source first");
          return;
        }
        if (source.kind === "desktop" && !source.connected) {
          respond(client.ws, msg, false, undefined, "selected desktop source is offline");
          return;
        }
        if (source.kind === "headless") {
          const desktopAttached = sources.list().some(
            (candidate) => candidate.kind === "desktop" && candidate.connected,
          );
          if (desktopAttached) {
            respond(
              client.ws,
              msg,
              false,
              undefined,
              "a desktop TUI is attached; detach it before starting headless control",
            );
            return;
          }
          headlessEnabled = true;
          if (!pi.alive) pi.start();
        } else if (pi.alive) {
          headlessEnabled = false;
          await pi.stopAndWait();
        }
        const ttlMs = clampLeaseTtl(msg.ttlMs, config.leaseMinTtlMs, config.leaseMaxTtlMs);
        const result = sources.acquire(source.id, client.clientId, ttlMs);
        if (!result?.ok) {
          respond(client.ws, msg, false, undefined, result?.error ?? "source not found");
          return;
        }
        respond(client.ws, msg, true, { ...result.lease, sourceId: source.id });
        notifyOwnerChanged(source.id);
        return;
      }

      case "hub_renew_owner": {
        const source = requireSelectedSource(client, msg);
        if (!source) return;
        if (
          typeof msg.leaseId !== "string" ||
          typeof msg.fence !== "number" ||
          !Number.isSafeInteger(msg.fence)
        ) {
          respond(client.ws, msg, false, undefined, "invalid lease identity");
          return;
        }
        const ttlMs = clampLeaseTtl(msg.ttlMs, config.leaseMinTtlMs, config.leaseMaxTtlMs);
        const result = sources.renew(
          source.id,
          client.clientId,
          msg.leaseId,
          msg.fence,
          ttlMs,
        );
        if (!result?.ok) {
          respond(client.ws, msg, false, undefined, result?.error ?? "source not found");
          return;
        }
        respond(client.ws, msg, true, { ...result.lease, sourceId: source.id });
        notifyOwnerChanged(source.id);
        return;
      }

      case "hub_release_owner": {
        const source = requireSelectedSource(client, msg);
        if (!source) return;
        const released = sources.release(
          source.id,
          client.clientId,
          typeof msg.leaseId === "string" ? msg.leaseId : undefined,
          typeof msg.fence === "number" ? msg.fence : undefined,
        );
        respond(client.ws, msg, released, released ? { released: true } : undefined, released ? undefined : "lease not held");
        if (released) notifyOwnerChanged(source.id);
        return;
      }

      default:
        respond(client.ws, msg, false, undefined, `unknown hub command: ${msg.type}`);
    }
  } catch (error) {
    respond(client.ws, msg, false, undefined, error instanceof Error ? error.message : String(error));
  }
}

async function handleBridgeCommand(client: MobileClient, msg: BridgeMessage): Promise<void> {
  try {
    switch (msg.type) {
      case "bridge_ping":
        sendObject(client.ws, { type: "bridge_pong", t: Date.now() });
        return;

      case "bridge_list_dirs":
        respond(client.ws, msg, true, { dirs: listDirs(), sessionsRoot: SESSIONS_ROOT });
        return;

      case "bridge_list_sessions": {
        const selected = client.selectedSourceId ? sources.get(client.selectedSourceId) : undefined;
        const cwd = typeof msg.cwd === "string" ? msg.cwd : (selected?.cwd ?? currentCwd);
        respond(client.ws, msg, true, { cwd, sessions: listSessions(cwd) });
        return;
      }

      case "bridge_switch_dir": {
        const source = requireSelectedSource(client, msg);
        if (!source || source.kind !== "headless") {
          if (source) respond(client.ws, msg, false, undefined, "directory switching requires the headless source");
          return;
        }
        if (!requireLease(client, source.id, msg)) return;
        if (typeof msg.cwd !== "string" || !path.isAbsolute(msg.cwd)) {
          respond(client.ws, msg, false, undefined, "cwd must be an absolute path");
          return;
        }
        const cwd = fs.realpathSync(msg.cwd);
        if (!fs.statSync(cwd).isDirectory()) {
          respond(client.ws, msg, false, undefined, "cwd is not a directory");
          return;
        }
        const requestedSession =
          typeof msg.sessionPath === "string"
            ? listSessions(cwd).find((session) => session.path === msg.sessionPath)
            : undefined;
        if (typeof msg.sessionPath === "string" && !requestedSession) {
          respond(client.ws, msg, false, undefined, "sessionPath is not an enumerated session for cwd");
          return;
        }
        let sessionId: string;
        let piArgs: string[];
        if (requestedSession) {
          sessionId = requestedSession.id;
          config.dirSessions[cwd] = sessionId;
          writeFileConfig({ dirSessions: config.dirSessions });
          piArgs = buildPiArgsForSessionPath(requestedSession.path, config.piFlagOpts);
        } else {
          sessionId = config.dirSessions[cwd] ?? crypto.randomUUID();
          if (config.dirSessions[cwd] !== sessionId) {
            config.dirSessions[cwd] = sessionId;
            writeFileConfig({ dirSessions: config.dirSessions });
          }
          piArgs = buildPiArgs(sessionId, config.piFlagOpts);
        }
        currentCwd = cwd;
        currentSessionId = sessionId;
        await pi.restart(piArgs, cwd);
        const event = sources.recordLocalEvent(HEADLESS_SOURCE_ID, {
          type: "bridge_dir_switched",
          cwd,
          sessionId,
        });
        if (event.ok) broadcastSourceEvent(event.event);
        respond(client.ws, msg, true, { cwd, sessionId });
        return;
      }

      case "bridge_get_config":
        respond(client.ws, msg, true, {
          piCwd: currentCwd,
          sessionId: currentSessionId,
          port: config.port,
          sessionsRoot: SESSIONS_ROOT,
          tokenPinned: !config.tokenGenerated,
          hubId: sources.hubId,
        });
        return;

      case "bridge_set_config": {
        const source = requireSelectedSource(client, msg);
        if (!source || !requireLease(client, source.id, msg)) return;
        if (typeof msg.token === "string" && msg.token.length >= 8) {
          config.token = msg.token;
          config.tokenGenerated = false;
          writeFileConfig({ token: msg.token });
          respond(client.ws, msg, true, { tokenUpdated: true });
        } else {
          respond(client.ws, msg, false, undefined, "unsupported field or weak token (min 8 chars)");
        }
        return;
      }

      default:
        respond(client.ws, msg, false, undefined, `unknown bridge command: ${msg.type}`);
    }
  } catch (error) {
    respond(client.ws, msg, false, undefined, error instanceof Error ? error.message : String(error));
  }
}

pi.onSpawn = () => {
  sources.setConnected(HEADLESS_SOURCE_ID, true, crypto.randomUUID());
  sources.updateMetadata(HEADLESS_SOURCE_ID, {
    cwd: currentCwd,
    sessionId: currentSessionId,
  });
  const event = sources.recordLocalEvent(HEADLESS_SOURCE_ID, {
    type: "bridge_pi_start",
    pid: pi.pid,
  });
  if (event.ok) broadcastSourceEvent(event.event);
  notifySourcesChanged();
};

pi.onExit = (code, signal) => {
  sources.setConnected(HEADLESS_SOURCE_ID, false);
  failPendingForSource(HEADLESS_SOURCE_ID, "headless pi process exited");
  broadcastHubEvent("hub_source_offline", { sourceId: HEADLESS_SOURCE_ID, code, signal });
  notifySourcesChanged();
  if (!shuttingDown && headlessEnabled && !pi.isIntentionalStop) {
    const timer = setTimeout(() => pi.start(), 1500);
    timer.unref();
  }
};

pi.onLine = (line) => {
  let message: JsonObject;
  try {
    message = JSON.parse(line) as JsonObject;
  } catch {
    return;
  }
  if (message.type === "response" && typeof message.id === "string") {
    const request = pending.get(message.id);
    if (request && message.command === "get_state" && message.data && typeof message.data === "object") {
      const state = message.data as JsonObject;
      sources.updateMetadata(HEADLESS_SOURCE_ID, {
        cwd: typeof state.cwd === "string" ? state.cwd : currentCwd,
        sessionId: typeof state.sessionId === "string" ? state.sessionId : currentSessionId,
        sessionFile: typeof state.sessionFile === "string" ? state.sessionFile : undefined,
        sessionName: typeof state.sessionName === "string" ? state.sessionName : undefined,
      });
    }
    resolvePending(message.id, message);
    return;
  }
  const event = sources.recordLocalEvent(HEADLESS_SOURCE_ID, message);
  if (event.ok) broadcastSourceEvent(event.event);
};

function parseSnapshot(value: unknown): SourceSnapshot | undefined {
  if (!value || typeof value !== "object") return undefined;
  const snapshot = value as Partial<SourceSnapshot>;
  if (
    typeof snapshot.epoch !== "string" ||
    typeof snapshot.baseSeq !== "number" ||
    !Number.isSafeInteger(snapshot.baseSeq) ||
    !snapshot.state ||
    typeof snapshot.state !== "object" ||
    !Array.isArray(snapshot.entries) ||
    !(typeof snapshot.leafId === "string" || snapshot.leafId === null)
  ) {
    return undefined;
  }
  return {
    epoch: snapshot.epoch,
    baseSeq: snapshot.baseSeq,
    capturedAt: typeof snapshot.capturedAt === "number" ? snapshot.capturedAt : Date.now(),
    state: snapshot.state as JsonObject,
    entries: snapshot.entries.filter(
      (entry): entry is JsonObject => Boolean(entry) && typeof entry === "object",
    ),
    leafId: snapshot.leafId,
    models: Array.isArray(snapshot.models)
      ? snapshot.models.filter((model): model is JsonObject => Boolean(model) && typeof model === "object")
      : undefined,
    thinkingLevels: Array.isArray(snapshot.thinkingLevels)
      ? snapshot.thinkingLevels.filter((level): level is string => typeof level === "string")
      : undefined,
    inFlightMessage:
      snapshot.inFlightMessage && typeof snapshot.inFlightMessage === "object"
        ? (snapshot.inFlightMessage as JsonObject)
        : undefined,
  };
}

async function stopHeadlessForDesktop(): Promise<void> {
  headlessEnabled = false;
  await quiesceSourceForHandoff({
    isConnected: () => sources.get(HEADLESS_SOURCE_ID)?.connected === true,
    blockNewCommands: () => {
      sources.setConnected(HEADLESS_SOURCE_ID, false);
    },
    failPending: () => {
      failPendingForSource(HEADLESS_SOURCE_ID, "headless source is handing off to desktop");
    },
    notifyOffline: () => {
      broadcastHubEvent("hub_source_offline", {
        sourceId: HEADLESS_SOURCE_ID,
        reason: "desktop_handoff",
      });
      notifySourcesChanged();
    },
    stopOwner: () => (pi.alive ? pi.stopAndWait() : Promise.resolve()),
  });
}

async function handleDesktopMessage(desktop: DesktopClient, text: string): Promise<void> {
  let msg: JsonObject;
  try {
    msg = JSON.parse(text) as JsonObject;
  } catch {
    sendObject(desktop.ws, { type: "desktop_error", error: "invalid JSON" });
    return;
  }

  if (msg.type === "desktop_register") {
    const source = msg.source;
    const snapshot = parseSnapshot(msg.snapshot);
    if (!source || typeof source !== "object" || !snapshot) {
      sendObject(desktop.ws, { type: "desktop_error", error: "invalid registration or snapshot" });
      return;
    }
    const raw = source as JsonObject;
    const sourceId = typeof raw.sourceId === "string" ? raw.sourceId : "";
    const label = typeof raw.label === "string" ? raw.label : sourceId;
    if (!/^[A-Za-z0-9._:-]{1,128}$/.test(sourceId) || !label) {
      sendObject(desktop.ws, { type: "desktop_error", error: "invalid source identity" });
      return;
    }
    if (desktop.registering) {
      sendObject(desktop.ws, { type: "desktop_error", error: "registration already in progress" });
      return;
    }
    desktop.registering = true;
    try {
      await stopHeadlessForDesktop();
    } catch (error) {
      sendObject(desktop.ws, {
        type: "desktop_error",
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    } finally {
      desktop.registering = false;
    }
    if (desktop.ws.readyState !== WebSocket.OPEN) return;

    const previous = desktopBySource.get(sourceId);
    if (previous && previous !== desktop) previous.ws.close(4009, "source replaced");
    desktop.sourceId = sourceId;
    desktopBySource.set(sourceId, desktop);
    const capabilities = Array.isArray(raw.capabilities)
      ? raw.capabilities.filter((value): value is string => typeof value === "string")
      : [];
    sources.register(
      {
        id: sourceId,
        kind: "desktop",
        label,
        connected: true,
        epoch: snapshot.epoch,
        cwd: typeof raw.cwd === "string" ? raw.cwd : undefined,
        sessionId: typeof raw.sessionId === "string" ? raw.sessionId : undefined,
        sessionFile: typeof raw.sessionFile === "string" ? raw.sessionFile : undefined,
        sessionName: typeof raw.sessionName === "string" ? raw.sessionName : undefined,
        capabilities,
      },
      { send: (message) => sendObject(desktop.ws, message) },
    );
    sources.setSnapshot(sourceId, snapshot);
    sendObject(desktop.ws, {
      type: "desktop_registered",
      hubId: sources.hubId,
      sourceId,
      epoch: snapshot.epoch,
    });
    notifySourcesChanged();
    return;
  }

  const sourceId = desktop.sourceId;
  if (!sourceId) {
    sendObject(desktop.ws, { type: "desktop_error", error: "register first" });
    return;
  }

  switch (msg.type) {
    case "desktop_snapshot": {
      const snapshot = parseSnapshot(msg.snapshot);
      if (!snapshot || !sources.setSnapshot(sourceId, snapshot)) {
        sendObject(desktop.ws, { type: "desktop_error", error: "invalid snapshot" });
        return;
      }
      sendObject(desktop.ws, { type: "desktop_ack", epoch: snapshot.epoch, seq: snapshot.baseSeq });
      notifySourcesChanged();
      return;
    }

    case "desktop_event": {
      if (
        typeof msg.epoch !== "string" ||
        typeof msg.seq !== "number" ||
        !msg.event ||
        typeof msg.event !== "object"
      ) {
        sendObject(desktop.ws, { type: "desktop_error", error: "invalid event" });
        return;
      }
      const result = sources.recordDesktopEvent(
        sourceId,
        msg.epoch,
        msg.seq,
        msg.event as JsonObject,
      );
      if (!result.ok) {
        sendObject(desktop.ws, {
          type: "desktop_resync_required",
          reason: result.error,
        });
        return;
      }
      broadcastSourceEvent(result.event);
      sendObject(desktop.ws, { type: "desktop_ack", epoch: msg.epoch, seq: msg.seq });
      return;
    }

    case "remote_result":
      if (typeof msg.requestId === "string") resolvePending(msg.requestId, msg);
      return;

    case "desktop_heartbeat":
      sendObject(desktop.ws, { type: "desktop_heartbeat_ack", t: Date.now() });
      return;

    default:
      sendObject(desktop.ws, { type: "desktop_error", error: `unknown message: ${msg.type}` });
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        ok: true,
        hubId: sources.hubId,
        piAlive: pi.alive,
        mobileClients: mobileClients.size,
        desktopSources: sources.list().filter((source) => source.kind === "desktop" && source.connected).length,
        cwd: currentCwd,
      }),
    );
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, maxPayload: MAX_DESKTOP_MESSAGE_BYTES });

function requestUrl(req: http.IncomingMessage): URL {
  return new URL(req.url ?? "/", "http://localhost");
}

function extractToken(req: http.IncomingMessage): string | null {
  try {
    const fromQuery = requestUrl(req).searchParams.get("token");
    if (fromQuery) return fromQuery;
  } catch {
    // Header auth may still be valid.
  }
  const auth = req.headers.authorization;
  return auth?.startsWith("Bearer ") ? auth.slice("Bearer ".length) : null;
}

function isLoopback(req: http.IncomingMessage): boolean {
  const address = req.socket.remoteAddress;
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

wss.on("connection", (ws, req) => {
  const desktopEndpoint = requestUrl(req).pathname === "/desktop";
  if (desktopEndpoint) {
    if (!isLoopback(req) || !tokenMatches(extractToken(req), config.desktopToken)) {
      ws.close(4001, "unauthorized desktop source");
      return;
    }
    const desktop: DesktopClient = { ws };
    desktopClients.add(desktop);
    sendObject(ws, {
      type: "desktop_hello",
      version: HUB_PROTOCOL_VERSION,
      hubId: sources.hubId,
    });
    ws.on("message", (data) => void handleDesktopMessage(desktop, data.toString()));
    ws.on("close", () => {
      desktopClients.delete(desktop);
      const sourceId = desktop.sourceId;
      if (!sourceId || desktopBySource.get(sourceId) !== desktop) return;
      desktopBySource.delete(sourceId);
      sources.setConnected(sourceId, false);
      failPendingForSource(sourceId, "desktop source disconnected");
      notifySourcesChanged();
    });
    ws.on("error", () => {});
    return;
  }

  if (!tokenMatches(extractToken(req), config.token)) {
    ws.close(4001, "unauthorized");
    return;
  }
  const client: MobileClient = { clientId: crypto.randomUUID(), ws };
  mobileClients.set(ws, client);
  sendObject(ws, {
    type: "bridge_hello",
    version: HUB_PROTOCOL_VERSION,
    hubId: sources.hubId,
    clientId: client.clientId,
    capabilities: ["sources", "replay", "snapshot", "owner-lease", "desktop-relay"],
  });

  ws.on("message", (data) => {
    const text = data.toString();
    if (Buffer.byteLength(text) > MAX_CLIENT_MESSAGE_BYTES) {
      ws.close(1009, "message too large");
      return;
    }
    let msg: BridgeMessage;
    try {
      msg = JSON.parse(text) as BridgeMessage;
    } catch {
      sendObject(ws, { type: "bridge_error", error: "invalid JSON" });
      return;
    }
    if (typeof msg.type !== "string") {
      respond(ws, msg, false, undefined, "message type is required");
      return;
    }
    if (msg.type.startsWith("hub_")) {
      void handleHubCommand(client, msg);
    } else if (msg.type.startsWith("bridge_")) {
      void handleBridgeCommand(client, msg);
    } else {
      handleSourceCommand(client, msg);
    }
  });

  ws.on("close", () => {
    mobileClients.delete(ws);
    const released = sources.releaseClient(client.clientId);
    for (const sourceId of released) notifyOwnerChanged(sourceId);
    for (const [requestId, request] of pending) {
      if (request.clientId !== client.clientId) continue;
      clearTimeout(request.timeout);
      pending.delete(requestId);
    }
    if (client.selectedSourceId) pushDesktopStatus(client.selectedSourceId);
  });
  ws.on("error", () => {});
});

const leaseTimer = setInterval(() => {
  for (const sourceId of sources.expireLeases()) notifyOwnerChanged(sourceId);
}, 1000);
leaseTimer.unref();

if (headlessEnabled) pi.start();

server.listen(config.port, config.host, () => {
  console.log("PiPilot Source Hub is up");
  console.log(`  hub id:        ${sources.hubId}`);
  console.log(`  headless cwd:  ${currentCwd}`);
  console.log(`  headless mode: ${headlessEnabled ? "enabled" : "disabled"}`);
  console.log("  desktop relay: loopback /desktop (credential stored in bridge/config.json)");
  console.log("  mobile auth:   configured (token omitted from logs)");
  console.log("  connect urls:");
  for (const url of lanUrls(config)) console.log(`    ${url}`);
});

async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  headlessEnabled = false;
  clearInterval(leaseTimer);
  for (const client of [...mobileClients.keys(), ...[...desktopClients].map((item) => item.ws)]) {
    client.close(1001, "bridge shutting down");
  }
  await pi.stopAndWait();
  server.close(() => process.exit(0));
  const forceExit = setTimeout(() => process.exit(0), 2000);
  forceExit.unref();
}
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
