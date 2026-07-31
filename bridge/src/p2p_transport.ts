/**
 * P2P 传输分级与自适应在飞信用。
 *
 * 问题背景:单条 reliable/ordered DataChannel 上,任何已压入 SCTP 缓冲的
 * 字节都是全序的 —— 队列分级只能决定"谁先进入缓冲",无法绕过已在缓冲中的
 * 数据。慢速 TURN(50KB/s)下若任由 bulk 把缓冲顶到数 MB,控制帧(ping/pong)
 * 与交互响应会被饿死几十秒:心跳照回但数据面已死。
 *
 * 对策:
 * 1. 三级分类(编码前按 type+大小判定):control / interactive / bulk。
 * 2. 自适应在飞信用:creditTarget = clamp(drainRateEMA × 0.4s, 1 片, 2MB)。
 *    快链路信用自动顶满保持流水线;慢链路信用收缩,Q0/Q1 到达时前方最多
 *    ~0.4s+1 片的 bulk。bufferedAmount 只作安全天花板。
 * 3. 背压 = 停泵,不杀链:只有连续 120s 无任何字节推进才判定链路死亡。
 */

export type P2pClass = "control" | "interactive" | "bulk";

/** 单片线帧上限(base64 后 48KB):信用的最小单位。 */
export const P2P_CREDIT_MIN_BYTES = 48 * 1024;
/** 在飞信用硬顶(同时是 bufferedAmount 安全天花板)。 */
export const P2P_CREDIT_MAX_BYTES = 2 * 1024 * 1024;
/** 信用目标 = 实测排空速率 × 这么多毫秒。 */
export const P2P_CREDIT_TARGET_MS = 400;
/** interactive 单帧上限:50KB/s 下单帧 ≤0.2s,不饿 bulk 不卡交互。 */
export const P2P_INTERACTIVE_FRAME_MAX_BYTES = 8 * 1024;

/**
 * 控制帧字节硬上限。
 *
 * 控制帧(ping/pong/ACK/NACK)本就只有几十到几百字节。超过 2KB 的"控制帧"
 * 要么不是真控制帧,要么是被构造来插队的 —— 一律降级到 bulk。
 */
export const P2P_CONTROL_FRAME_MAX_BYTES = 2 * 1024;
/** interactive 应用层排队上限:超过即对新请求执行前拒答(busy),响应永不丢。 */
export const P2P_INTERACTIVE_QUEUE_MAX_BYTES = 2 * 1024 * 1024;
/** bulk 应用层排队上限:超过即丢帧并记日志(由客户端进度型超时驱动重试)。 */
export const P2P_BULK_QUEUE_MAX_BYTES = 32 * 1024 * 1024;
/** 连续这么久没有任何字节推进才判定链路死亡(慢链路合法大消息可持续数分钟)。 */
export const P2P_NO_PROGRESS_CLOSE_MS = 120_000;
/**
 * 未实测前的排空速率假设。取 128KB/s(初始信用 ~51KB,刚过单片下限)而不是
 * 1MB/s:首屏那几片是在完全没有测量数据时发出的,乐观初值会在慢 TURN 上
 * 一次压入 400KB(≈8s 的队列),控制帧要等这 8s 才出得去。宁可从保守窗口起步,
 * 快链路几个采样就能靠 EMA 涨到硬顶。
 */
const DRAIN_RATE_INITIAL_BPS = 128 * 1024;
/** 速率估计的下限:避免衰减到 0 后再也涨不回来。 */
const DRAIN_RATE_FLOOR_BPS = 4 * 1024;
/** 测速窗口的最小时长:窗口太短,单次整片下降会被除出离谱的速率。 */
const DRAIN_SAMPLE_MIN_MS = 20;
/**
 * 测速窗口的最大时长。超过就认为窗口已失效,重置基线而不据此算速率。
 *
 * 判据是「有没有人在采样」:真正在发送时,泵的背压循环每 5ms 就 sample 一次,
 * dt 不可能到秒级。dt 一大只有一种解释 —— 泵空闲了一段时间没人采样。
 * 此时拿旧 windowBuffered 与新 buffered 相减,分母是整段空闲时长,算出来的
 * 速率必然荒谬地低。
 *
 * 真机实测:热态残留 80KB,空闲 15s 后心跳触发一次采样,80KB÷15s 被算成
 * 5.4KB/s,几个周期后 drainBps 就掉到 4KB/s 地板 —— 空闲之后的第一批数据
 * 于是从最保守的信用窗口起步。
 */
const DRAIN_SAMPLE_MAX_MS = 2_000;
/** 缓冲完全不动这么久,就把速率估计对折(链路可能已经变慢或停了)。 */
const DRAIN_STALL_DECAY_MS = 1_000;

const CONTROL_TYPES = new Set([
  "bridge_ping",
  "bridge_pong",
  "transfer_ack",
  "transfer_nack",
  "transfer_drop",
  "rpc_cancel",
]);

const INTERACTIVE_TYPES = new Set([
  "hub_sessions_changed",
  "hub_sources_changed",
  "hub_owner_changed",
  "hub_control_moved",
  "bridge_error",
]);

/**
 * 顶层 `type` 字段的值。找不到(或不是顶层字符串)返回 undefined。
 *
 * 为什么不用 JSON.parse:分类发生在每一次 send 上,而 hub_sync 响应可以是
 * MB 级 —— 为了读一个字段去解析整份 JSON 太贵。这里做带深度跟踪的有界扫描,
 * 通常在头几十字节就命中(JSON.stringify 会把 type 放在对象构造顺序的位置)。
 *
 * 为什么不用子串匹配:已复现过一条 10,072B 的普通响应,因为 payload 文本里
 * 嵌了 `{"type":"bridge_ping"}` 而被判成 control,直接插到控制队列最前面。
 * 普通载荷能冒充控制帧,优先级与预算分类就都失效了。
 */
export function topLevelType(json: string): string | undefined {
  // 扫描上限:顶层键必然在开头附近;扫过这个长度还没命中就当作无 type。
  const limit = Math.min(json.length, 64 * 1024);
  let i = 0;
  while (i < limit && json[i] !== "{") {
    if (!/\s/.test(json[i]!)) return undefined; // 顶层不是对象
    i++;
  }
  if (json[i] !== "{") return undefined;
  i++;
  let depth = 1;
  while (i < limit) {
    const ch = json[i]!;
    if (ch === '"') {
      // 读一个字符串(可能是键,也可能是值)
      const start = i + 1;
      let j = start;
      let raw = "";
      while (j < json.length) {
        const c = json[j]!;
        if (c === "\\") {
          raw += json[j + 1] ?? "";
          j += 2;
          continue;
        }
        if (c === '"') break;
        raw += c;
        j++;
      }
      i = j + 1;
      // 只认深度 1 上的键 "type"
      if (depth === 1 && raw === "type") {
        // 跳过空白与冒号
        while (i < json.length && (json[i] === ":" || /\s/.test(json[i]!))) i++;
        if (json[i] !== '"') return undefined; // type 不是字符串
        i++;
        let value = "";
        while (i < json.length) {
          const c = json[i]!;
          if (c === "\\") {
            value += json[i + 1] ?? "";
            i += 2;
            continue;
          }
          if (c === '"') break;
          value += c;
          i++;
        }
        return value;
      }
      continue;
    }
    if (ch === "{" || ch === "[") depth++;
    else if (ch === "}" || ch === "]") {
      depth--;
      if (depth === 0) return undefined; // 顶层对象结束,没有 type
    }
    i++;
  }
  return undefined;
}

/**
 * 按**顶层 type** 与 UTF-8 字节数分类。
 *
 * - control 另设 [P2P_CONTROL_FRAME_MAX_BYTES] 硬上限:控制帧本就是极小帧,
 *   超限说明不是真控制帧(或被构造),降级到 bulk,免得插队塞住控制队列。
 * - 大 response 永远归 bulk:把 MB 级快照响应提进交互队列会反向堵死交互。
 * - 字节数用 Buffer.byteLength 而不是 String.length:CJK 一字 3 字节,
 *   按 UTF-16 长度判定会让 8KB 阈值实际放行到 24KB。
 */
export function classifyFrame(json: string): P2pClass {
  const type = topLevelType(json);
  if (type === undefined) return "bulk";
  const bytes = Buffer.byteLength(json);
  if (CONTROL_TYPES.has(type)) {
    return bytes <= P2P_CONTROL_FRAME_MAX_BYTES ? "control" : "bulk";
  }
  if (type === "response") {
    return bytes <= P2P_INTERACTIVE_FRAME_MAX_BYTES ? "interactive" : "bulk";
  }
  if (INTERACTIVE_TYPES.has(type) || type.startsWith("hub_ask")) {
    return bytes <= P2P_INTERACTIVE_FRAME_MAX_BYTES ? "interactive" : "bulk";
  }
  return "bulk";
}

/**
 * 自适应在飞信用计算器:采样 bufferedAmount 的下降速率(EMA),
 * 输出"允许压入 SCTP 缓冲的目标字节数"。双端(Dart/TS)算法一致。
 */
export class CreditController {
  private rateBps = DRAIN_RATE_INITIAL_BPS;
  /** 测速窗口起点:锚定在上一次真实排空,而不是上一次采样。 */
  private windowAt = 0;
  private windowBuffered = 0;
  private lastProgressAt = Date.now();

  /** 当前在飞信用目标(字节)。 */
  get target(): number {
    const target = this.rateBps * (P2P_CREDIT_TARGET_MS / 1000);
    return Math.max(P2P_CREDIT_MIN_BYTES, Math.min(P2P_CREDIT_MAX_BYTES, Math.floor(target)));
  }

  /** 距上次字节推进的毫秒数(供"无进度杀链"判定)。 */
  get noProgressMs(): number {
    return Date.now() - this.lastProgressAt;
  }

  /**
   * 每次发送循环采样一次:buffered 下降即为推进,更新速率 EMA。
   *
   * 关键:测速窗口锚定在「上一次真实排空」,不是「上一次采样」。慢链路的
   * bufferedAmount 形态是「长时间不动,然后整片下降」——若每次平坦采样都把
   * 窗口起点推到当前时刻,那一次整片下降就会被除以最小采样间隔(~20ms),
   * 把 50KB/s 的 TURN 误判成 MB/s 级。实测过的后果:36KB 在 ~700ms 后落下,
   * 却被算成 1.84MB/s,信用目标涨到 ~500KB,等于允许十几秒的 bulk 排在
   * pong 前面 —— 健康慢链路被心跳判死,进而反复重连。
   */
  sample(buffered: number, nowMs = Date.now()): void {
    if (this.windowAt === 0) {
      this.windowAt = nowMs;
      this.windowBuffered = buffered;
      this.lastProgressAt = nowMs;
      return;
    }
    // 缓冲变大 = 又压入了新帧:重置基线,别把新增字节算成「负排空」。
    if (buffered > this.windowBuffered) {
      this.windowAt = nowMs;
      this.windowBuffered = buffered;
      return;
    }
    const drained = this.windowBuffered - buffered;
    const dt = nowMs - this.windowAt;
    // 排空即算推进(与测速窗口是否够长无关),供无进度杀链判定。
    if (drained > 0) this.lastProgressAt = nowMs;
    if (drained <= 0) {
      // 平坦期:不推进窗口起点,让下一次下降能拿到完整耗时。但长时间完全
      // 不动时要衰减估计值,否则会一直吃着旧的高信用。
      //
      // 只有 buffered > 0 才算"停滞":缓冲是空的说明根本没有东西要排空,
      // 这不是链路慢的证据。真机实测过后果 —— 空闲期每 15s 一次心跳都会
      // 让估计值对折,几分钟后 drainBps 从 128KB/s 掉到 4KB/s 地板,
      // 空闲之后的第一批数据于是从最保守的信用窗口起步。
      if (buffered > 0 && dt >= DRAIN_STALL_DECAY_MS) {
        this.rateBps = Math.max(DRAIN_RATE_FLOOR_BPS, this.rateBps * 0.5);
        this.windowAt = nowMs;
      } else if (buffered === 0) {
        // 空闲:把窗口起点跟上,避免下次真有数据时用一个跨越整段空闲的 dt
        // 去算速率(会把速率算得极低)。
        this.windowAt = nowMs;
      }
      return;
    }
    // 窗口跨度过大 = 中间没人采样(泵空闲过)。这不是一次有效吞吐测量:
    // 无法知道这些字节是在窗口的哪一段排掉的。重置基线,不更新速率。
    if (dt > DRAIN_SAMPLE_MAX_MS) {
      this.windowAt = nowMs;
      this.windowBuffered = buffered;
      return;
    }
    // 窗口还太短:先把排空字节留在窗口里累积,下次采样再算。
    if (dt < DRAIN_SAMPLE_MIN_MS) return;
    const instant = (drained * 1000) / dt;
    this.rateBps = this.rateBps * 0.7 + instant * 0.3;
    this.windowAt = nowMs;
    this.windowBuffered = buffered;
  }

  /** 成功把一帧交付 SCTP 也算推进证据(从空缓冲开始时)。 */
  noteSent(): void {
    this.lastProgressAt = Date.now();
  }
}
