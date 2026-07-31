export const P2P_DEVICE_ID_MIN_LENGTH = 3;
export const P2P_DEVICE_ID_MAX_LENGTH = 64;
export const P2P_PAIRING_KEY_MIN_LENGTH = 16;
export const P2P_PAIRING_KEY_MAX_LENGTH = 128;

const DEVICE_ID_PATTERN = /^[A-Za-z0-9._-]{3,64}$/;
const PRINTABLE_ASCII_PATTERN = /^[\x21-\x7e]+$/;

/** Mirror the rendezvous device-name policy before opening a signaling socket. */
export function isValidP2pDeviceId(value: string): boolean {
  return DEVICE_ID_PATTERN.test(value);
}

/** Mirror the rendezvous pairing-key policy; the server remains authoritative. */
export function isValidP2pPairingKey(value: string): boolean {
  if (
    value.length < P2P_PAIRING_KEY_MIN_LENGTH ||
    value.length > P2P_PAIRING_KEY_MAX_LENGTH ||
    !PRINTABLE_ASCII_PATTERN.test(value)
  ) {
    return false;
  }

  let classes = 0;
  if (/[a-z]/.test(value)) classes++;
  if (/[A-Z]/.test(value)) classes++;
  if (/[0-9]/.test(value)) classes++;
  if (/[^A-Za-z0-9]/.test(value)) classes++;
  return classes >= 3;
}
