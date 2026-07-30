const EXPLICIT_URL_SCHEME = /^[a-z][a-z0-9+.-]*:\/\//i;

/** 裸域名默认走 WSS;显式 scheme 保留给后续安全校验。 */
export function normalizeP2pSignalingUrl(value: string): string {
  const trimmed = value.trim();
  if (!trimmed || EXPLICIT_URL_SCHEME.test(trimmed)) return trimmed;
  return `wss://${trimmed}`;
}

function isLoopbackHostname(hostname: string): boolean {
  const host = hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (host === "localhost" || host === "::1") return true;
  const octets = host.split(".").map(Number);
  return (
    octets.length === 4 &&
    octets[0] === 127 &&
    octets.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)
  );
}

/** 公网信令必须由 TLS 认证;明文 ws 只允许本机测试。 */
export function isAllowedP2pSignalingUrl(value: string): boolean {
  try {
    const url = new URL(normalizeP2pSignalingUrl(value));
    if (!url.hostname || url.username || url.password) return false;
    if (url.protocol === "wss:") return true;
    return url.protocol === "ws:" && isLoopbackHostname(url.hostname);
  } catch {
    return false;
  }
}
