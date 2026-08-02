import {
  hostname,
  networkInterfaces,
  type NetworkInterfaceInfo,
} from "node:os";

import Bonjour from "bonjour-service";

export interface AnnounceOptions {
  port: number;
  hubId: string;
  protocolVersion: number;
  /** mDNS 实例名,默认主机名(「书房的 Mac」)。 */
  name?: string;
  /// 跨重启稳定的 Bridge 身份。hubId 每次启动都变,手机在 DHCP 换址后
  /// 需要一个稳定值确认「还是原来那台机器」。两者并存,见 stable-plan.md §3.2。
  bridgeInstallationId?: string;
  /// 是否支持通知事件协议。旧客户端看不懂就忽略,新客户端靠它决定
  /// 能不能发通知帧,避免对旧 Bridge 发未知帧。
  notificationEvents?: boolean;
}

export type AnnounceNetworkInterfaces = Record<
  string,
  readonly Pick<NetworkInterfaceInfo, "address" | "family" | "internal">[] | undefined
>;

const VIRTUAL_INTERFACE =
  /^(?:br-|docker|veth|virbr|vmnet|vbox|utun|tun|tap|wg|tailscale|zt|meta$)|virtual|hyper-v|wsl/i;

function isPrivateIpv4(address: string): boolean {
  const octets = address.split(".").map(Number);
  if (
    octets.length !== 4 ||
    octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)
  ) {
    return false;
  }
  const [first, second] = octets;
  return (
    first === 10 ||
    (first === 172 && second !== undefined && second >= 16 && second <= 31) ||
    (first === 192 && second === 168)
  );
}

function interfaceScore(name: string): number | undefined {
  if (VIRTUAL_INTERFACE.test(name)) return undefined;
  if (/^(?:wl|wlan)|wi-?fi|wireless/i.test(name)) return 300;
  if (/^(?:en|eth)|ethernet/i.test(name)) return 200;
  return 100;
}

/** Pick one reachable physical-LAN IPv4 instead of Docker/VPN interfaces. */
export function selectLanIpv4(
  interfaces: AnnounceNetworkInterfaces = networkInterfaces(),
): string | undefined {
  let selected: { address: string; score: number } | undefined;
  for (const [name, addresses] of Object.entries(interfaces)) {
    const score = interfaceScore(name);
    if (score === undefined) continue;
    for (const address of addresses ?? []) {
      if (
        address.internal ||
        address.family !== "IPv4" ||
        !isPrivateIpv4(address.address)
      ) {
        continue;
      }
      if (selected === undefined || score > selected.score) {
        selected = { address: address.address, score };
      }
    }
  }
  return selected?.address;
}

/**
 * mDNS 自我宣告:发布 `_pipilot._tcp`,让手机在局域网里「找得到」。
 *
 * TXT 只放非机密元数据(hubId / 协议版本 / 认证方式)——token 永远不上广播,
 * 「连得上」仍要 App 侧走添加流程输入配对 token。
 *
 * 返回停止函数;发布失败(无组播网络/权限)降级为 no-op,不影响主功能。
 */
export function startAnnounce(options: AnnounceOptions): () => void {
  const name = options.name ?? hostname();
  const lanIpv4 = selectLanIpv4();
  if (lanIpv4 === undefined) {
    console.warn("[announce] 未找到物理私网 IPv4,局域网自动发现不可用");
    return () => {};
  }
  try {
    // bonjour-service 的构造类型漏掉了底层 multicast-dns 参数,运行时会透传。
    const bonjour = new Bonjour(
      { interface: lanIpv4 } as unknown as ConstructorParameters<typeof Bonjour>[0],
    );
    const service = bonjour.publish({
      name,
      type: "pipilot", // → _pipilot._tcp.local
      port: options.port,
      txt: {
        hubId: options.hubId,
        v: String(options.protocolVersion),
        auth: "token",
        // 双字段过渡:旧客户端只读 hubId,行为完全不变;
        // 新客户端优先读 bridgeId,但必须在已鉴权的 bridge_hello 里复核 ——
        // mDNS TXT 可被同网设备伪造,它只是发现提示,不是信任根。
        ...(options.bridgeInstallationId !== undefined
          ? { bridgeId: options.bridgeInstallationId }
          : {}),
        ...(options.notificationEvents === true ? { notify: "1" } : {}),
        // bonjour-service 会把所有 Docker/VPN 地址都放进 A 记录。
        // App 端优先读这个明确的物理 LAN 地址,避免 Android NSD 选错。
        ipv4: lanIpv4,
      },
    });
    console.log(
      `[announce] mDNS 已发布 _pipilot._tcp(${name}:${options.port}) via ${lanIpv4}`,
    );
    return () => {
      try {
        service.stop?.(() => {});
        bonjour.destroy();
      } catch {
        // 退出路径,停不掉无碍。
      }
    };
  } catch (error) {
    console.warn("[announce] mDNS 发布失败,局域网自动发现不可用:", error);
    return () => {};
  }
}
