const MIN_PAIRING_KEY_LENGTH = 16;
const MAX_PAIRING_KEY_LENGTH = 128;
const MIN_PAIRING_KEY_CLASSES = 3;

const DEVICE_ID_PATTERN = /^[A-Za-z0-9._-]{3,64}$/;
const PRINTABLE_ASCII_PATTERN = /^[\x21-\x7e]+$/;

/**
 * Validate a pairing key before it is accepted by the rendezvous server.
 * The key is intentionally restricted to printable ASCII so length and
 * character classes are stable across Dart, Node, and JSON transports.
 */
export function validatePairingKey(value: unknown): boolean {
  if (typeof value !== "string") return false;
  if (value.length < MIN_PAIRING_KEY_LENGTH || value.length > MAX_PAIRING_KEY_LENGTH) {
    return false;
  }
  if (!PRINTABLE_ASCII_PATTERN.test(value)) return false;

  let classes = 0;
  if (/[a-z]/.test(value)) classes++;
  if (/[A-Z]/.test(value)) classes++;
  if (/[0-9]/.test(value)) classes++;
  if (/[^A-Za-z0-9]/.test(value)) classes++;
  return classes >= MIN_PAIRING_KEY_CLASSES;
}

/** Device names are room identifiers and must be safe to use as opaque IDs. */
export function validateDeviceId(value: unknown): value is string {
  return typeof value === "string" && DEVICE_ID_PATTERN.test(value);
}

export const pairingKeyPolicy = {
  minLength: MIN_PAIRING_KEY_LENGTH,
  maxLength: MAX_PAIRING_KEY_LENGTH,
  minCharacterClasses: MIN_PAIRING_KEY_CLASSES,
} as const;
