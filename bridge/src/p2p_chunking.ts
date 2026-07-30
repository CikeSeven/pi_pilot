import crypto from "node:crypto";

export const P2P_CHUNK_CAPABILITY = "p2p-chunk-v1";
const PREFIX = "~pipilot-chunk-v1~";
const DIRECT_BYTES = 48 * 1024;
const CHUNK_BYTES = 36 * 1024;
const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
const MAX_CHUNKS = Math.ceil(MAX_MESSAGE_BYTES / CHUNK_BYTES);
const MAX_PENDING_MESSAGES = 8;
const MAX_PENDING_BYTES = 32 * 1024 * 1024;
const CHUNK_TTL_MS = 30_000;

export function encodeP2pFrames(data: string): string[] {
  const bytes = Buffer.from(data, "utf8");
  if (bytes.length <= DIRECT_BYTES) return [data];
  if (bytes.length > MAX_MESSAGE_BYTES)
    throw new Error("P2P message exceeds 16MB");
  const id = crypto.randomBytes(8).toString("hex");
  const total = Math.ceil(bytes.length / CHUNK_BYTES);
  const frames: string[] = [];
  for (let index = 0; index < total; index++) {
    const part = bytes.subarray(index * CHUNK_BYTES, (index + 1) * CHUNK_BYTES);
    frames.push(`${PREFIX}${id}:${index}:${total}:${part.toString("base64")}`);
  }
  return frames;
}

interface PendingMessage {
  total: number;
  parts: Array<Buffer | undefined>;
  received: number;
  bytes: number;
  timer: NodeJS.Timeout;
}

export class P2pChunkDecoder {
  private readonly pending = new Map<string, PendingMessage>();
  private pendingBytes = 0;

  add(frame: string): string | undefined {
    if (!frame.startsWith(PREFIX)) return frame;
    const rest = frame.slice(PREFIX.length);
    const first = rest.indexOf(":");
    const second = rest.indexOf(":", first + 1);
    const third = rest.indexOf(":", second + 1);
    if (first <= 0 || second <= first || third <= second) return undefined;
    const id = rest.slice(0, first);
    const index = Number(rest.slice(first + 1, second));
    const total = Number(rest.slice(second + 1, third));
    if (
      !/^[a-zA-Z0-9_-]{1,64}$/.test(id) ||
      !Number.isInteger(index) ||
      !Number.isInteger(total) ||
      total < 2 ||
      total > MAX_CHUNKS ||
      index < 0 ||
      index >= total
    )
      return undefined;
    const encoded = rest.slice(third + 1);
    if (
      encoded.length === 0 ||
      encoded.length % 4 !== 0 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
        encoded,
      )
    ) {
      return undefined;
    }
    const part = Buffer.from(encoded, "base64");
    if (part.toString("base64") !== encoded || part.length > CHUNK_BYTES) {
      return undefined;
    }

    let message = this.pending.get(id);
    if (!message || message.total !== total) {
      if (message) this.drop(id, message);
      if (this.pending.size >= MAX_PENDING_MESSAGES) {
        const oldestId = this.pending.keys().next().value as string | undefined;
        if (oldestId) this.drop(oldestId);
      }
      const timer = setTimeout(() => this.drop(id), CHUNK_TTL_MS);
      timer.unref();
      message = {
        total,
        parts: new Array(total),
        received: 0,
        bytes: 0,
        timer,
      };
      this.pending.set(id, message);
    }
    if (!message.parts[index]) {
      message.parts[index] = part;
      message.received++;
      message.bytes += part.length;
      this.pendingBytes += part.length;
    }
    if (
      message.bytes > MAX_MESSAGE_BYTES ||
      this.pendingBytes > MAX_PENDING_BYTES
    ) {
      this.drop(id, message);
      return undefined;
    }
    if (message.received < message.total) return undefined;
    this.drop(id, message);
    return Buffer.concat(message.parts as Buffer[]).toString("utf8");
  }

  close(): void {
    for (const [id, message] of this.pending) this.drop(id, message);
  }

  private drop(id: string, expected?: PendingMessage): void {
    const message = this.pending.get(id);
    if (!message || (expected && message !== expected)) return;
    clearTimeout(message.timer);
    this.pendingBytes = Math.max(0, this.pendingBytes - message.bytes);
    this.pending.delete(id);
  }
}
