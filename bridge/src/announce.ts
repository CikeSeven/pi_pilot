import { hostname } from "node:os";

import Bonjour from "bonjour-service";

export interface AnnounceOptions {
  port: number;
  hubId: string;
  protocolVersion: number;
  /** mDNS 实例名,默认主机名(「书房的 Mac」)。 */
  name?: string;
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
  try {
    const bonjour = new Bonjour();
    const service = bonjour.publish({
      name,
      type: "pipilot", // → _pipilot._tcp.local
      port: options.port,
      txt: {
        hubId: options.hubId,
        v: String(options.protocolVersion),
        auth: "token",
      },
    });
    console.log(`[announce] mDNS 已发布 _pipilot._tcp(${name}:${options.port})`);
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
