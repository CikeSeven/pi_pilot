const MAX_EVENT_BYTES = 1024 * 1024;
export const MAX_SNAPSHOT_BYTES = 12 * 1024 * 1024;

function replacer(_key: string, value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Error) {
    return { name: value.name, message: value.message, stack: value.stack };
  }
  return value;
}

export function cloneForWire<T>(value: T, maxBytes = MAX_EVENT_BYTES): T {
  const encoded = JSON.stringify(value, replacer);
  if (encoded === undefined) throw new Error("value is not JSON serializable");
  if (Buffer.byteLength(encoded) > maxBytes) {
    throw new Error(`serialized payload exceeds ${maxBytes} bytes`);
  }
  return JSON.parse(encoded) as T;
}

export function encodeForWire(value: unknown, maxBytes = MAX_EVENT_BYTES): string {
  const encoded = JSON.stringify(value, replacer);
  if (encoded === undefined) throw new Error("value is not JSON serializable");
  if (Buffer.byteLength(encoded) > maxBytes) {
    throw new Error(`serialized payload exceeds ${maxBytes} bytes`);
  }
  return encoded;
}
