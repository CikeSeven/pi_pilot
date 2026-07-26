export const HUB_PROTOCOL_VERSION = 2;
export const MAX_CLIENT_MESSAGE_BYTES = 1024 * 1024;
export const MAX_DESKTOP_MESSAGE_BYTES = 16 * 1024 * 1024;
export const MAX_BUFFERED_SOCKET_BYTES = 2 * 1024 * 1024;

export type JsonObject = Record<string, unknown>;

export interface HubCommandMeta {
  leaseId?: string;
  fence?: number;
}

export interface HubCursor {
  hubId: string;
  sourceId: string;
  sourceEpoch: string;
  seq: number;
}

export interface BridgeMessage extends JsonObject {
  type?: string;
  id?: string;
  _hub?: HubCommandMeta;
}

const READ_ONLY_SOURCE_COMMANDS = new Set([
  "get_state",
  "get_entries",
  "get_available_models",
  "get_available_thinking_levels",
  "get_session_stats",
]);

const DESKTOP_MUTATION_COMMANDS = new Set([
  "prompt",
  "abort",
  "set_model",
  "set_thinking_level",
]);

export function isReadOnlySourceCommand(type: string): boolean {
  return READ_ONLY_SOURCE_COMMANDS.has(type);
}

export function isDesktopMutationCommand(type: string): boolean {
  return DESKTOP_MUTATION_COMMANDS.has(type);
}

export function withoutHubMetadata(message: BridgeMessage): BridgeMessage {
  const { _hub: _ignored, ...command } = message;
  return command;
}

export function parseCursor(value: unknown): HubCursor | undefined {
  if (!value || typeof value !== "object") return undefined;
  const cursor = value as Partial<HubCursor>;
  if (
    typeof cursor.hubId !== "string" ||
    typeof cursor.sourceId !== "string" ||
    typeof cursor.sourceEpoch !== "string" ||
    typeof cursor.seq !== "number" ||
    !Number.isSafeInteger(cursor.seq) ||
    cursor.seq < 0
  ) {
    return undefined;
  }
  return cursor as HubCursor;
}

export function clampLeaseTtl(value: unknown, minMs: number, maxMs: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return maxMs;
  return Math.max(minMs, Math.min(maxMs, Math.floor(value)));
}
