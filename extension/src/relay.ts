import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RelayConfig } from "./config.js";
import {
  navRuntimeFor,
  runNavigate,
  type NavCommandContextCache,
  type NavResult,
} from "./nav_commands.js";
import { sourceLabel } from "./git_branch.js";
import { executeRemoteCommand, SAFE_REMOTE_COMMANDS, type RemoteCommand } from "./remote_commands.js";
import { cloneForWire, encodeForWire, MAX_SNAPSHOT_BYTES } from "./serialization.js";

type JsonObject = Record<string, unknown>;

const MAX_SOCKET_BUFFER = 2 * 1024 * 1024;
const MAX_CAPTURE_BYTES = 64 * 1024 * 1024;
const HEARTBEAT_MS = 10_000;
const MAX_COMMAND_QUEUE = 32;
const MAX_COMMAND_RESULTS = 256;
/** Hub 用它判断 relay 是否支持独立的按需会话树帧。 */
const LIVE_TREE_CAPABILITY = "tree-summary-on-demand";
/** Hub 用它判断 relay 是否会把 ask_user_question 问卷转给手机。 */
const LIVE_ASK_CAPABILITY = "ask-user-question-relay";

/**
 * 补进命令表的 pi 内置命令。
 *
 * pi 的内置斜杠命令住在 dist/core/slash-commands.js,只给交互模式的自动补全用,
 * `getCommands()` 只返回扩展注册的命令 —— 所以手机上以前根本看不见 /compact。
 * `source` 标成 builtin,App 靠它决定派发成远程命令而不是当文本发出去。
 */
const BUILTIN_COMPACT = {
  name: "compact",
  description: "压缩上下文(在电脑端执行)",
  source: "builtin",
} as const;

/**
 * 第三方插件 @juicesharp/rpiv-ask-user-question 注册的工具名。
 *
 * 它的问卷是电脑端 TUI 的覆盖层(`ctx.ui.custom()`),不走 pi 的
 * extension_ui_request 协议,所以手机永远收不到;插件本身也是严格单向的
 * (全仓只有两处 `pi.events.emit`、零处 `pi.events.on`),没有任何可编程
 * 应答入口。于是手机上只能看着一个转不完的圈。
 *
 * 同名注册顶不掉它 —— runner.js 的规则是**先注册者赢**,而 settings.json 里
 * 插件(第 10 位)排在 PiPilot relay(最后一位)之前。所以只能在它的
 * `execute` 跑起来之前用 `tool_call` 钩子把整次调用截下来。
 */
const ASK_TOOL_NAME = "ask_user_question";
const MAX_ASK_QUESTIONS = 4;
const MAX_ASK_OPTIONS = 8;
const MAX_ASK_PREVIEW = 2_000;

/**
 * 思考时长持久化文件(msgTs -> ms)。
 *
 * 手机端只能现算「它连着时看到的流」;断线重连、锁屏后一次性到位的
 * 消息它算不出时长,胶囊退化成「已思考」。relay 在 pi 进程里看着每
 * 一条 delta,是唯一全量的来源 —— 把结果持久化,pi 重启后回放老会
 * 话也能补上。
 */
const THINKING_DURATIONS_PATH = path.join(
  os.homedir(),
  ".pi",
  "agent",
  "pipilot-thinking-durations.json",
);
/** LRU 上限:一条 assistant 消息一对键值,4000 条覆盖几百个会话。 */
const MAX_THINKING_DURATIONS = 4_000;
/** 在途跟踪上限(正常同时只有一条 assistant 在流)。 */
const MAX_THINKING_PROGRESS = 32;
/** 写盘节流。 */
const THINKING_DURATIONS_SAVE_MS = 5_000;

/**
 * 答案信封的开头。
 *
 * **必须**留着。`tool_call` 钩子能返回的只有 `{block, reason}`,而
 * agent-loop.js 里 block 那一支是:
 *
 * ```js
 * return { kind: "immediate", result: createErrorToolResult(reason), isError: true };
 * ```
 *
 * `isError: true` 是常量,钩子改不了,所以一次**成功**的作答会被协议层标成
 * 失败。这段话是唯一能纠正它的地方 —— 少了它,模型会把用户的选择当成工具
 * 报错,然后重试或者放弃。
 *
 * (想干净地把 isError 改回 false 只能用 `tool_result` 钩子,但 block 走的是
 * `kind: "immediate"`,而 `afterToolCall` 只在 `else` 分支的
 * `finalizeExecutedToolCall` 里调 —— block 之后它根本不触发。)
 */
const ASK_ANSWER_HEADER =
  "The user answered this questionnaire on their phone through PiPilot. " +
  "This is a SUCCESSFUL answer, NOT an error and NOT a decline: the error " +
  "envelope around it is a transport artifact of intercepting the desktop " +
  "questionnaire, not a failure. Treat the answers below as the user's " +
  "decision and continue. Do not retry the tool.";

function clipText(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`;
}

/**
 * 把插件的问卷参数收成手机端渲染够用的最小形状。
 *
 * 这些字段是**模型**写的,长度不可预期,而它们要过 WebSocket,所以逐项截断;
 * 结构不合法(没题干、没选项)的直接丢掉 —— 一道都不剩就返回 undefined,
 * 让插件照常在电脑上问,别把一个空问卷推到手机上。
 */
function normalizeAskQuestions(input: unknown): JsonObject[] | undefined {
  if (!input || typeof input !== "object") return undefined;
  const raw = (input as JsonObject).questions;
  if (!Array.isArray(raw) || raw.length === 0) return undefined;
  const questions: JsonObject[] = [];
  for (const item of raw.slice(0, MAX_ASK_QUESTIONS)) {
    if (!item || typeof item !== "object") continue;
    const q = item as JsonObject;
    const text = typeof q.question === "string" ? q.question.trim() : "";
    if (!text) continue;
    const rawOptions = Array.isArray(q.options) ? q.options : [];
    const options: JsonObject[] = [];
    for (const opt of rawOptions.slice(0, MAX_ASK_OPTIONS)) {
      if (!opt || typeof opt !== "object") continue;
      const o = opt as JsonObject;
      const label = typeof o.label === "string" ? o.label.trim() : "";
      if (!label) continue;
      const description = typeof o.description === "string" ? o.description.trim() : "";
      const preview = typeof o.preview === "string" ? o.preview : "";
      options.push({
        label: clipText(label, 200),
        ...(description ? { description: clipText(description, 600) } : {}),
        ...(preview ? { preview: clipText(preview, MAX_ASK_PREVIEW) } : {}),
      });
    }
    if (options.length === 0) continue;
    const header = typeof q.header === "string" ? q.header.trim() : "";
    questions.push({
      question: clipText(text, 1_000),
      ...(header ? { header: clipText(header, 60) } : {}),
      ...(q.multiSelect === true ? { multiSelect: true } : {}),
      options,
    });
  }
  return questions.length > 0 ? questions : undefined;
}

/** 把手机回来的结构化答案摊成模型读的文本。空答案返回 undefined(按回落处理)。 */
function formatAskAnswers(raw: unknown): string | undefined {
  if (!Array.isArray(raw) || raw.length === 0) return undefined;
  const lines: string[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const a = item as JsonObject;
    const question = typeof a.question === "string" ? a.question.trim() : "";
    const labels = Array.isArray(a.labels)
      ? a.labels.filter((l): l is string => typeof l === "string" && l.trim().length > 0)
      : [];
    const text = typeof a.text === "string" ? a.text.trim() : "";
    // 自定义输入(插件的 "Type something." 那一行)走 text,选项走 labels
    const answer = labels.length > 0 ? labels.join(", ") : text;
    if (!question || !answer) continue;
    lines.push(`Q: ${question}`);
    lines.push(`A: ${clipText(answer, 2_000)}`);
    const notes = typeof a.notes === "string" ? a.notes.trim() : "";
    if (notes) lines.push(`Note: ${clipText(notes, 1_000)}`);
  }
  if (lines.length === 0) return undefined;
  return [ASK_ANSWER_HEADER, "", ...lines].join("\n");
}

/** 一次在途的问卷转交。`timer` 会在认领前后换一次(认领窗口 → 作答窗口)。 */
interface PendingAsk {
  resolve: (answer: string | undefined) => void;
  timer: NodeJS.Timeout;
  claimed: boolean;
}

function serializeModel(model: ExtensionContext["model"]): JsonObject | null {
  if (!model) return null;
  return {
    id: model.id,
    name: model.name,
    provider: model.provider,
    api: model.api,
    reasoning: model.reasoning,
    input: model.input,
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    cost: model.cost,
  };
}

function sanitizeSourceId(value: string): string {
  return value.replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 128);
}

/** treeSummary 的 UTF-8 字节预算。既用于快照兼容字段,也用于按需树响应。 */
const TREE_SUMMARY_BYTE_BUDGET = 256 * 1024;

/// treeSummary 的最大嵌套深度。
///
/// 会话树是一条长单链,深度 == 消息数。`JSON.stringify` 和 app 侧的解析都受
/// 各自的栈深限制,实测 2600 层能过、4000 层在 stringify 里就 RangeError。
/// 留足余量取 2000。
const MAX_TREE_SUMMARY_DEPTH = 2000;

/** 与 pi getSessionStats 同形状的统计(从 branch entries 汇总)。 */
export function computeSessionStats(
  entries: readonly unknown[],
  contextUsage: unknown,
): JsonObject {
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let cost = 0;
  let userMessages = 0;
  let assistantMessages = 0;
  let toolResults = 0;
  let toolCalls = 0;
  let totalMessages = 0;
  const add = (usage: any): void => {
    if (!usage) return;
    input += usage.input ?? 0;
    output += usage.output ?? 0;
    cacheRead += usage.cacheRead ?? 0;
    cacheWrite += usage.cacheWrite ?? 0;
    cost += usage.cost?.total ?? 0;
  };
  for (const raw of entries) {
    const entry = raw as any;
    if ((entry?.type === "branch_summary" || entry?.type === "compaction") && entry.usage) {
      add(entry.usage);
    }
    if (entry?.type !== "message") continue;
    totalMessages++;
    const message = entry.message;
    if (message?.role === "user") {
      userMessages++;
    } else if (message?.role === "toolResult") {
      toolResults++;
      add(message.usage);
    } else if (message?.role === "assistant") {
      assistantMessages++;
      if (Array.isArray(message.content)) {
        toolCalls += message.content.filter((c: any) => c?.type === "toolCall").length;
      }
      add(message.usage);
    }
  }
  return {
    userMessages,
    assistantMessages,
    toolCalls,
    toolResults,
    totalMessages,
    tokens: {
      input,
      output,
      cacheRead,
      cacheWrite,
      total: input + output + cacheRead + cacheWrite,
    },
    cost,
    contextUsage: contextUsage ?? null,
  };
}

/// 会话树里**能作为回退目标**的 entry 类型。
///
/// pi 的会话文件里还有大量 model_change / thinking_level_change / custom 节点
/// (实测某个 2558 条会话里就占了 1008 个),它们既不是回退目标、界面也从不
/// 渲染,只是链上的一环。把它们过滤掉、子节点接到最近的保留祖先上,
/// 省下的预算正好用来保住**每一条真实消息的 id**。
const NAVIGABLE_TREE_TYPES = new Set(["message", "compaction", "branch_summary"]);

/// 会话树节点的原始形态(pi sessionManager.getTree() 的元素)。
interface RawTreeNode {
  entry?: any;
  children?: RawTreeNode[];
  label?: string | null;
}

function isNavigable(node: RawTreeNode): boolean {
  return NAVIGABLE_TREE_TYPES.has(node?.entry?.type);
}

/// 摘要 leafId 的重映射:原始 leaf 可能是被投影丢掉的噪音节点(msg-meta
/// 这类 custom 是常客 —— 生成一停它就挂在会话尾巴上),摘要里根本没有它,
/// App 的「定位到当前位置」和 currentPath 会一起落空(生成中叶是正在写的
/// assistant 消息所以能定位,一停就不行)。沿 parentId 向上走到最近的可导
/// 航节点;leaf 不在树里或整链都不可导航时返回 null。
export function navigableLeafId(tree: unknown[], leafId: string | null): string | null {
  if (!leafId) return null;
  const byId = new Map<string, any>();
  const stack = [...(tree ?? [])] as RawTreeNode[];
  while (stack.length > 0) {
    const node = stack.pop()!;
    const entry = node?.entry;
    if (entry && typeof entry.id === "string") byId.set(entry.id, entry);
    for (const child of node?.children ?? []) stack.push(child);
  }
  let current: string | null = leafId;
  // 防御 parentId 环(损坏的转录),走死就放弃
  const seen = new Set<string>();
  while (current !== null && !seen.has(current)) {
    seen.add(current);
    const entry = byId.get(current);
    if (!entry) return null;
    if (NAVIGABLE_TREE_TYPES.has(entry.type)) return current;
    current = typeof entry.parentId === "string" ? entry.parentId : null;
  }
  return null;
}

/// 时间戳转 epoch 毫秒数字。
///
/// pi 写的是 ISO 字符串(24 字节),数字只需 13 字节 —— 千条规模下这一项就差
/// 十几 KB。而且 app 侧 `_timeFrom` 本来只认 int,拿到字符串会退成
/// `DateTime.now()`,导致会话树里每条都显示「刚刚」—— 转数字后一并修好。
function toEpochMs(ts: unknown): number | undefined {
  if (typeof ts === "number" && Number.isFinite(ts)) return ts;
  if (typeof ts === "string") {
    const ms = Date.parse(ts);
    if (Number.isFinite(ms)) return ms;
  }
  return undefined;
}

function treePreview(entry: any, limit: number): string {
  if (limit <= 0 || entry?.type !== "message") return "";
  const content = entry.message?.content;
  let preview = "";
  if (typeof content === "string") preview = content;
  else if (Array.isArray(content)) {
    preview = content
      .filter((c: any) => c?.type === "text")
      .map((c: any) => c.text)
      .join(" ");
  }
  preview = preview.trim();
  return preview.length > limit ? `${preview.slice(0, limit)}…` : preview;
}

/// assistant 回合里调用的工具名(去重、限 4 个)。
///
/// 只有 thinking + toolCall 的 assistant 回合没有任何文本,预览是空的,
/// 界面上就只剩一个 "message" 字样 —— 而「这一步调了 bash」恰恰是人回退时要找的锚点。
function toolCallNames(entry: any): string | undefined {
  if (entry?.type !== "message") return undefined;
  const content = entry.message?.content;
  if (!Array.isArray(content)) return undefined;
  const names: string[] = [];
  for (const block of content) {
    if (block?.type !== "toolCall") continue;
    const name = typeof block.name === "string" ? block.name : undefined;
    if (name && !names.includes(name)) names.push(name);
    if (names.length >= 4) break;
  }
  return names.length > 0 ? names.join(",") : undefined;
}

/// 单个节点的压缩形态(**不含子节点**,children 由调用方迭代填充)。
///
/// 为 null 的字段直接不输出 —— 千条规模下 `"label":null` 这类占位就是几十 KB,
/// 而 app 侧 `as String?` 对缺字段与 null 同义。`parentId` 也不输出:
/// 嵌套结构本身已经编码了父子关系,app 侧也没有用到它。
function summarizeTreeNode(node: RawTreeNode, previewLimit: number): JsonObject {
  const entry = node?.entry ?? {};
  const preview = treePreview(entry, previewLimit);
  const role = entry.type === "message" ? (entry.message?.role ?? null) : null;
  const timestamp = toEpochMs(entry.timestamp);
  // toolResult 没有文本预览,工具名字是区分它们的唯一信息
  const toolName = role === "toolResult" ? (entry.message?.toolName ?? null) : null;
  const tools = role === "assistant" ? toolCallNames(entry) : undefined;
  return {
    id: entry.id,
    type: entry.type ?? "unknown",
    ...(timestamp != null ? { timestamp } : {}),
    ...(role ? { role } : {}),
    ...(toolName ? { toolName } : {}),
    ...(tools ? { tools } : {}),
    ...(entry.message?.isError === true ? { isError: true } : {}),
    ...(preview ? { preview } : {}),
    ...(node?.label ? { label: node.label } : {}),
    children: [] as JsonObject[],
  };
}

/// 会话树是**一条长单链**(每回合一个节点,没有分叉时深度 == 节点数),
/// 所以任何按 children 递归的写法都会在千条会话上爆栈。爆栈会被
/// captureSnapshot 的 try/catch 吞成 `treeSummary = undefined`,
/// 表现和超预算一模一样:「会话树不可用」。这里全部改成显式栈迭代。
function buildSummaryTree(
  tree: RawTreeNode[],
  previewLimit: number,
  keep?: Set<RawTreeNode>,
): JsonObject[] {
  const roots: JsonObject[] = [];
  // omitted:从最近一个保留祖先到本节点之间被剔掉的节点数
  const stack: { node: RawTreeNode; sink: JsonObject[]; omitted: number }[] = [];
  for (let i = tree.length - 1; i >= 0; i--) {
    stack.push({ node: tree[i]!, sink: roots, omitted: 0 });
  }
  while (stack.length > 0) {
    const { node, sink, omitted } = stack.pop()!;
    const kept = !keep || keep.has(node);
    let childSink = sink;
    let childOmitted = omitted;
    if (kept) {
      const out = summarizeTreeNode(node, previewLimit);
      if (omitted > 0) out.collapsedBefore = omitted;
      sink.push(out);
      childSink = out.children as JsonObject[];
      childOmitted = 0;
    } else {
      // 被剔掉:子节点挂到同一个 sink 上,并累加折叠计数
      childOmitted = omitted + 1;
    }
    const children = node?.children ?? [];
    for (let i = children.length - 1; i >= 0; i--) {
      stack.push({ node: children[i]!, sink: childSink, omitted: childOmitted });
    }
  }
  return roots;
}

/// 把原始树投影成**只包含可回退节点**的树。
///
/// 被过滤的节点子代接到最近的保留祖先上。这一步是**静默**的:
/// model_change / thinking_level_change / custom 不计入 `collapsedBefore`,
/// 因为它们不是“被省略的消息”,报给用户只是噪声。
function projectNavigable(tree: RawTreeNode[]): RawTreeNode[] {
  const roots: RawTreeNode[] = [];
  const stack: { node: RawTreeNode; sink: RawTreeNode[] }[] = [];
  for (let i = tree.length - 1; i >= 0; i--) {
    stack.push({ node: tree[i]!, sink: roots });
  }
  while (stack.length > 0) {
    const { node, sink } = stack.pop()!;
    let childSink = sink;
    if (isNavigable(node)) {
      const copy: RawTreeNode = {
        entry: node.entry,
        children: [],
        ...(node.label ? { label: node.label } : {}),
      };
      sink.push(copy);
      childSink = copy.children!;
    }
    const children = node?.children ?? [];
    for (let i = children.length - 1; i >= 0; i--) {
      stack.push({ node: children[i]!, sink: childSink });
    }
  }
  return roots;
}

/// 树的最大深度(迭代量,不递归)。
function maxDepth(tree: RawTreeNode[]): number {
  let deepest = 0;
  const stack: { node: RawTreeNode; depth: number }[] = tree.map((node) => ({
    node,
    depth: 1,
  }));
  while (stack.length > 0) {
    const { node, depth } = stack.pop()!;
    if (depth > deepest) deepest = depth;
    for (const child of node?.children ?? []) stack.push({ node: child, depth: depth + 1 });
  }
  return deepest;
}

/// 结构剪枝的保留集(只在紧凑编码仍超预算时才用得上)。
///
/// 优先保留人回退时真正会找的锚点:分叉点、分支头、叶子、非 message 节点
/// (压缩/分支摘要)、书签,以及尾部一段。中间那些连续的 assistant/toolResult
/// 才是可折叠的部分。
///
/// `keepUserMessages` 必须可关:用户消息是很好的锚点,但**保留规则不能压过深度下限**。
/// 一条全是 user 消息的长单链若无条件全保,剪枝就一个都剪不掉,深度不降,
/// `JSON.stringify` 继续爆栈 —— 最后仍然是「会话树不可用」。所以深层降级要关掉它。
function collectKeepSet(
  tree: RawTreeNode[],
  tailCount: number,
  keepUserMessages = true,
): Set<RawTreeNode> {
  const order: RawTreeNode[] = [];
  const stack: RawTreeNode[] = [];
  for (let i = tree.length - 1; i >= 0; i--) stack.push(tree[i]!);
  while (stack.length > 0) {
    const node = stack.pop()!;
    order.push(node);
    const children = node?.children ?? [];
    for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]!);
  }

  const keep = new Set<RawTreeNode>(tree);
  for (const node of order) {
    const children = node?.children ?? [];
    // 线性中间节点才是 children.length === 1;分叉点与叶子都要留
    if (children.length !== 1) keep.add(node);
    if (children.length > 1) for (const child of children) keep.add(child);
    if (node?.entry?.type && node.entry.type !== "message") keep.add(node);
    if (keepUserMessages && node?.entry?.message?.role === "user") keep.add(node);
    if (node?.label) keep.add(node);
  }
  for (const node of order.slice(-Math.max(0, tailCount))) keep.add(node);
  return keep;
}

/// 压缩会话树。
///
/// **逐级降级,而不是超预算就整体剔掉**。以前这里是全有或全无:一超预算就
/// 返回 undefined,`treeSummary` 从快照里消失,bridge 只能回
/// "desktop snapshot does not include a tree",app 显示「会话树不可用」。
///
/// 目标是「每一条消息都能回退」,所以剪枝是**最后才用**的手段。先用两道
/// 不丢 id 的手段把体积降下来:
///   a) 过滤噪声类型(model_change / thinking_level_change / custom) ——
///      它们不是回退目标也从不渲染,实测占了 2558 条会话的 1008 个
///   b) 紧凑编码:去掉冗余 `parentId`、时间戳改 epoch 数字、null 字段不输出
/// 实测这两道就能把 2558 条会话的 1605 条真实消息全部装进预算。
///
/// 预算不能直接调大:`treeSummary` 搭在**每一份快照**里,包括流式期间的
/// 保活快照(最快约 15 秒一份),调大就是持续往手机推大包。
export function buildTreeSummary(tree: unknown[]): JsonObject[] | undefined {
  const raw = (tree ?? []) as JsonObject[] as RawTreeNode[];
  // JSON.stringify 自身是递归的,几千层嵌套会 RangeError 爆栈;而这个异常会被
  // captureSnapshot 的 try/catch 吞成 treeSummary = undefined,表现和超预算
  // 完全一样。所以先量深度,超了就直接进剪枝层把链压短。
  const fits = (summary: JsonObject[]) => {
    try {
      // 协议限制是字节而不是 JS UTF-16 code unit。中文预览通常是 3 字节,
      // 用 string.length 会把实际负载低估到约三分之一。
      return Buffer.byteLength(JSON.stringify(summary)) <= TREE_SUMMARY_BYTE_BUDGET;
    } catch {
      return false;
    }
  };

  // 1) 保住每一条消息的 id,只逐级缩预览
  const nav = projectNavigable(raw);
  if (maxDepth(nav) <= MAX_TREE_SUMMARY_DEPTH) {
    for (const previewLimit of [120, 80, 60, 40, 0]) {
      const summary = buildSummaryTree(nav, previewLimit);
      if (fits(summary)) return summary;
    }
  }
  // 2) 实在装不下(或链太深)才剪枝:尾部保留段逐步收紧。
  //    后几层关掉「保留用户消息」——那条规则不能压过深度下限。
  const layers: { tail: number; keepUsers: boolean }[] = [
    { tail: 800, keepUsers: true },
    { tail: 400, keepUsers: true },
    { tail: 400, keepUsers: false },
    { tail: 200, keepUsers: false },
    { tail: 80, keepUsers: false },
    { tail: 30, keepUsers: false },
  ];
  for (const { tail, keepUsers } of layers) {
    const keep = collectKeepSet(nav, tail, keepUsers);
    const summary = buildSummaryTree(nav, 40, keep);
    if (fits(summary)) return summary;
  }
  // 3) 最后一招:只给骨架
  const keep = collectKeepSet(nav, 10, false);
  const skeleton = buildSummaryTree(nav, 0, keep);
  return fits(skeleton) ? skeleton : undefined;
}

/** 读会话文件路径;陈旧 ctx 的 getter 会抛,这里吞掉。 */
function safeSessionFile(ctx: ExtensionContext): string | undefined {
  try {
    return ctx.sessionManager.getSessionFile() ?? undefined;
  } catch {
    return undefined;
  }
}

/// 队列镜像的上界:pi 消费排队消息不会回调扩展,镜像只能在回合边界收敛。
const MAX_QUEUE_MIRROR = 32;

export class DesktopRelay {
  private socket: WebSocket | undefined;
  private ctx: ExtensionContext | undefined;
  private active = false;
  private registered = false;
  private epoch = crypto.randomUUID();
  private seq = 0;
  private reconnectAttempt = 0;
  private reconnectTimer: NodeJS.Timeout | undefined;
  private heartbeatTimer: NodeJS.Timeout | undefined;
  private messageTimer: NodeJS.Timeout | undefined;
  private toolTimer: NodeJS.Timeout | undefined;
  private pendingMessageUpdate: JsonObject | undefined;
  private pendingToolUpdates = new Map<string, JsonObject>();
  private inFlightMessage: JsonObject | undefined;
  private highestFence = 0;
  private ownerActive = false;
  private ownerFence = 0;
  private ownerExpiresAt = 0;
  private controlGeneration = 0;
  private commandDepth = 0;
  private commandChain: Promise<void> = Promise.resolve();
  private activeRequests = new Set<string>();
  private commandResults = new Map<string, JsonObject>();
  private compacting = false;
  private streaming = false;
  private snapshotTimer: NodeJS.Timeout | undefined;
  /// 绑定的会话文件:ctx 对象每次 emit 都换,只有它是稳定的。
  private boundSessionFile: string | undefined;
  /// 合成队列镜像(pi 的 queue_update 不经过扩展事件流)。
  /// 有界:pi 消费一条排队消息不会通知扩展,所以镜像只能靠回合边界收敛,
  /// 中间必然偏大 —— 至少不能无界增长。
  private readonly steeringMirror: string[] = [];
  private readonly followUpMirror: string[] = [];
  private lastSnapshotAt = 0;
  private lastSnapshotSeq = 0;
  /// 有多少手机端正在看这个源(hub 的 desktop_status 推来)。
  /// 问卷转交的门控:为 0 时不拦截,插件照常在电脑上弹它那套完整问卷。
  private selectedClients = 0;
  private pendingAsks = new Map<string, PendingAsk>();

  /// 思考时长跟踪:msgTs -> 首个/最后 thinking 增长时刻 + 上次长度。
  /// 只在长度**增长**时推进 last —— thinking 停下后时长定格,
  /// 正文生成时间不会被算进「思考了 Xs」。
  private thinkingProgress = new Map<
    number,
    { first: number; last: number; len: number }
  >();
  /// 已定局的思考时长(msgTs -> ms),持久化,重启后回放可补。
  private thinkingDurations = new Map<number, number>();
  private thinkingDurationsDirty = false;
  private thinkingSaveTimer: NodeJS.Timeout | undefined;

  readonly sourceId = sanitizeSourceId(`${os.hostname()}:${process.pid}`);

  constructor(
    private readonly pi: ExtensionAPI,
    private readonly config: RelayConfig,
    private readonly navCache?: NavCommandContextCache,
  ) {
    this.loadThinkingDurations();
  }

  start(ctx: ExtensionContext): void {
    this.stopInternal(false);
    this.ctx = ctx;
    this.boundSessionFile = safeSessionFile(ctx);
    this.active = true;
    this.setStatus("PiPilot: connecting");
    this.connect();
  }

  stop(ctx: ExtensionContext): void {
    if (!this.isBound(ctx)) return;
    this.flushCoalesced();
    this.stopInternal(true);
  }

  dispose(): void {
    this.stopInternal(true);
  }

  /** session_before_compact / session_compact 事件驱动的压缩标志。 */
  setCompacting(value: boolean, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.compacting = value;
  }

  /// agent_start / agent_settled 驱动。流式期间定期自发快照,
  /// 这样中途加入的手机端拿到的快照带得上 isStreaming 与 inFlightMessage。
  setStreaming(value: boolean, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    if (this.streaming === value) return;
    this.streaming = value;
    if (!value) {
      this.clearSnapshotTimer();
      return;
    }
    this.lastSnapshotAt = Date.now();
    this.lastSnapshotSeq = this.seq;
    this.snapshotTimer = setInterval(() => this.streamSnapshotTick(), 1000);
    this.snapshotTimer.unref?.();
  }

  private streamSnapshotTick(): void {
    if (!this.registered || !this.liveCtx()) return;
    const grew = this.seq - this.lastSnapshotSeq;
    if (grew <= 0) return;
    if (
      grew >= this.config.streamSnapshotEvents ||
      Date.now() - this.lastSnapshotAt >= this.config.streamSnapshotMaxMs
    ) {
      this.sendSnapshot("streaming keepalive");
    }
  }

  private clearSnapshotTimer(): void {
    if (this.snapshotTimer) clearInterval(this.snapshotTimer);
    this.snapshotTimer = undefined;
  }

  emitBoundary(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.flushCoalesced();
    this.sendEvent(event);
  }

  /**
   * 桌面端即将换会话/开分支/回退。
   *
   * 这些操作会让 relay 短暂离线并换 epoch。发一个提示帧让手机知道"这是切换,
   * 不是掉线",避免它拆掉整个界面再重建。
   */
  emitSessionTransition(reason: string, ctx: ExtensionContext): void {
    this.emitEvent({ type: "pipilot_session_transition", reason }, ctx);
  }

  /**
   * 合成队列镜像。
   *
   * pi 的 `queue_update` **不经过扩展事件流**(它只发给 `session.subscribe`),
   * 所以桌面源上手机永远看不到队列。这里由 relay 自己维护:手机发来的消息
   * 明细我们知道,电脑端自己排的只能算个数 —— 所以帧上带 `partial: true`。
   */
  noteRemoteQueued(message: string, deliverAs: "steer" | "followUp", ctx: ExtensionContext): void {
    const queue = deliverAs === "steer" ? this.steeringMirror : this.followUpMirror;
    queue.push(message);
    if (queue.length > MAX_QUEUE_MIRROR) queue.splice(0, queue.length - MAX_QUEUE_MIRROR);
    this.emitQueueMirror(ctx);
  }

  /**
   * 中断:pi 会把未发送的排队消息**回填到电脑端输入框**,它们不再排队。
   * 镜像必须立刻清空,否则手机会一直显示一批根本不存在的待发消息。
   */
  noteAborted(ctx: ExtensionContext): void {
    this.clearQueueMirror(ctx);
  }

  clearQueueMirror(ctx: ExtensionContext): void {
    if (this.steeringMirror.length === 0 && this.followUpMirror.length === 0) return;
    this.steeringMirror.length = 0;
    this.followUpMirror.length = 0;
    this.emitQueueMirror(ctx);
  }

  private emitQueueMirror(ctx: ExtensionContext): void {
    this.emitEvent(
      {
        type: "queue_update",
        steering: [...this.steeringMirror],
        followUp: [...this.followUpMirror],
        partial: true,
      },
      ctx,
    );
  }

  emitEvent(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.sendEvent(event);
  }

  /**
   * working-activity 插件(TUI Working 行)的纯文本状态镜像。
   *
   * 走 pi.events 总线进来,不属于某个具体会话 ctx —— 状态行是「这个 pi
   * 正在干什么」的全局信息,手机灵动岛直接显示,和桌面 Working 行同源。
   */
  sendActivityStatus(text: string | null): void {
    this.sendEvent({ type: "working_activity", text });
  }

  emitMessageUpdate<T extends { message?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx)) return;
    try {
      const cloned = cloneForWire(event) as JsonObject;
      this.pendingMessageUpdate = cloned;
      if (cloned.message && typeof cloned.message === "object") {
        this.inFlightMessage = cloned.message as JsonObject;
        this.noteThinkingProgress(cloned.message);
      }
    } catch {
      this.resnapshot("message update too large");
      return;
    }
    if (!this.messageTimer) {
      this.messageTimer = setTimeout(() => {
        this.messageTimer = undefined;
        const pending = this.pendingMessageUpdate;
        this.pendingMessageUpdate = undefined;
        if (pending) this.sendEvent(pending);
      }, 25);
      this.messageTimer.unref();
    }
  }

  emitMessageEnd(event: unknown, ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.flushMessageUpdate();
    this.sendEvent(this.settleThinkingDuration(event));
    this.inFlightMessage = undefined;
  }

  /**
   * 从 message_update 里跟踪 thinking 块的增长。
   *
   * 手机端自己也现算,但它只能看着「自己连着时」的流;断线重连/锁屏
   * 后一次性到位的消息它算不出。relay 在 pi 进程里看着每一条 delta,
   * 是全量的唯一来源 —— 算好的值附到 message_end 和快照上发出去。
   */
  private noteThinkingProgress(message: unknown): void {
    if (!message || typeof message !== "object") return;
    const msg = message as JsonObject;
    if (msg.role !== "assistant" || typeof msg.timestamp !== "number") return;
    const content = msg.content;
    if (!Array.isArray(content)) return;
    let thinkingLen = 0;
    for (const block of content) {
      if (!block || typeof block !== "object") continue;
      const b = block as JsonObject;
      if (b.type === "thinking" && typeof b.thinking === "string") {
        thinkingLen += b.thinking.length;
      }
    }
    if (thinkingLen === 0) return;
    const msgTs = msg.timestamp;
    const prev = this.thinkingProgress.get(msgTs);
    // 没增长:不动。时长定格在最后一次增长,正文时间不计入。
    if (prev && prev.len >= thinkingLen) return;
    const now = Date.now();
    this.thinkingProgress.set(msgTs, {
      first: prev?.first ?? now,
      last: now,
      len: thinkingLen,
    });
    if (this.thinkingProgress.size > MAX_THINKING_PROGRESS) {
      const oldest = this.thinkingProgress.keys().next().value;
      if (oldest !== undefined) this.thinkingProgress.delete(oldest);
    }
  }

  /// message_end 结算:返回附带 thinkingDurationMs 的事件(有值的话)。
  private settleThinkingDuration(event: unknown): unknown {
    if (!event || typeof event !== "object") return event;
    const evt = event as JsonObject;
    const msg = evt.message;
    if (!msg || typeof msg !== "object") return event;
    const m = msg as JsonObject;
    if (typeof m.timestamp !== "number") return event;
    const msgTs = m.timestamp;
    const progress = this.thinkingProgress.get(msgTs);
    this.thinkingProgress.delete(msgTs);
    let ms =
      progress && progress.last > progress.first
        ? progress.last - progress.first
        : undefined;
    if (ms !== undefined) {
      this.thinkingDurations.set(msgTs, ms);
      this.thinkingDurationsDirty = true;
      this.trimThinkingDurations();
      this.scheduleSaveThinkingDurations();
    } else {
      // 这条消息的流式没经过本 relay(比如手机端 sync 触发的):
      // 查查持久化里有没有老值。
      ms = this.thinkingDurations.get(msgTs);
    }
    if (ms === undefined) return event;
    return { ...evt, message: { ...m, thinkingDurationMs: ms } };
  }

  /// 快照里的 assistant entries 补时长(历史回放路径)。
  private attachThinkingDurations(entries: JsonObject[]): void {
    if (this.thinkingDurations.size === 0) return;
    for (const entry of entries) {
      const msg = entry?.message;
      if (!msg || typeof msg !== "object") continue;
      const m = msg as JsonObject;
      if (m.role !== "assistant" || typeof m.timestamp !== "number") continue;
      if (typeof m.thinkingDurationMs === "number") continue;
      const ms = this.thinkingDurations.get(m.timestamp);
      if (ms !== undefined) m.thinkingDurationMs = ms;
    }
  }

  private trimThinkingDurations(): void {
    while (this.thinkingDurations.size > MAX_THINKING_DURATIONS) {
      const oldest = this.thinkingDurations.keys().next().value;
      if (oldest === undefined) break;
      this.thinkingDurations.delete(oldest);
    }
  }

  private loadThinkingDurations(): void {
    try {
      const raw = fs.readFileSync(THINKING_DURATIONS_PATH, "utf8");
      const data = JSON.parse(raw) as Record<string, number>;
      for (const [k, v] of Object.entries(data)) {
        const msgTs = Number(k);
        if (Number.isFinite(msgTs) && typeof v === "number" && v > 0) {
          this.thinkingDurations.set(msgTs, v);
        }
      }
      this.trimThinkingDurations();
    } catch {
      // 没有文件或损坏:从零开始,不致命。
    }
  }

  private scheduleSaveThinkingDurations(): void {
    if (this.thinkingSaveTimer) return;
    this.thinkingSaveTimer = setTimeout(() => {
      this.thinkingSaveTimer = undefined;
      this.flushThinkingDurations();
    }, THINKING_DURATIONS_SAVE_MS);
    this.thinkingSaveTimer.unref();
  }

  /** 立即写盘(若脏)。session_shutdown 时由 index.ts 调用。 */
  flushThinkingDurations(): void {
    if (!this.thinkingDurationsDirty) return;
    try {
      fs.mkdirSync(path.dirname(THINKING_DURATIONS_PATH), { recursive: true });
      const data: Record<string, number> = {};
      for (const [k, v] of this.thinkingDurations) data[String(k)] = v;
      fs.writeFileSync(THINKING_DURATIONS_PATH, JSON.stringify(data));
      this.thinkingDurationsDirty = false;
    } catch {
      // 写不进就算了,下次启动重新跟踪新消息。
    }
  }

  emitToolUpdate<T extends { toolCallId?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx) || typeof event.toolCallId !== "string") return;
    try {
      this.pendingToolUpdates.set(event.toolCallId, cloneForWire(event) as JsonObject);
    } catch {
      this.resnapshot("tool update too large");
      return;
    }
    if (!this.toolTimer) {
      this.toolTimer = setTimeout(() => {
        this.toolTimer = undefined;
        this.flushToolUpdates();
      }, 100);
      this.toolTimer.unref();
    }
  }

  emitToolEnd<T extends { toolCallId?: unknown }>(
    event: T,
    ctx: ExtensionContext,
  ): void {
    if (!this.isCurrent(ctx)) return;
    if (typeof event.toolCallId === "string") {
      const pending = this.pendingToolUpdates.get(event.toolCallId);
      if (pending) {
        this.pendingToolUpdates.delete(event.toolCallId);
        this.sendEvent(pending);
      }
    }
    this.sendEvent(event);
  }

  snapshot(ctx: ExtensionContext): void {
    if (!this.isCurrent(ctx)) return;
    this.sendSnapshot("state changed");
  }

  private connect(): void {
    if (!this.active || this.socket) return;
    const socket = new WebSocket(this.config.url, { handshakeTimeout: 5_000 });
    this.socket = socket;

    socket.on("open", () => {
      if (this.socket !== socket || !this.active) return;
      this.reconnectAttempt = 0;
      this.registered = false;
      this.newEpoch();
      try {
        this.sendRegistration();
      } catch (err) {
        this.setStatus(
          `PiPilot: registration failed (${err instanceof Error ? err.message : String(err)})`,
        );
      }
    });
    socket.on("message", (data) => this.handleHubMessage(data.toString()));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.registered = false;
      this.clearHeartbeat();
      if (this.active) {
        this.setStatus("PiPilot: reconnecting");
        this.scheduleReconnect();
      }
    });
    socket.on("error", () => socket.close());
  }

  private handleHubMessage(text: string): void {
    let msg: JsonObject;
    try {
      msg = JSON.parse(text) as JsonObject;
    } catch {
      return;
    }
    switch (msg.type) {
      case "desktop_registered":
        if (msg.epoch !== this.epoch) return;
        this.registered = true;
        this.setStatus("PiPilot: synced");
        this.startHeartbeat();
        this.sendSnapshot("registration barrier");
        return;

      case "desktop_status": {
        const selected = typeof msg.selectedClients === "number" ? msg.selectedClients : 0;
        this.selectedClients = selected;
        const owner = msg.owner && typeof msg.owner === "object" ? (msg.owner as JsonObject) : {};
        const nextOwnerActive = owner.owned === true;
        const nextOwnerFence =
          nextOwnerActive && typeof owner.fence === "number" && Number.isSafeInteger(owner.fence)
            ? owner.fence
            : 0;
        const nextOwnerExpiresAt =
          nextOwnerActive &&
          typeof owner.expiresAt === "number" &&
          Number.isSafeInteger(owner.expiresAt)
            ? owner.expiresAt
            : 0;
        if (nextOwnerActive !== this.ownerActive || nextOwnerFence !== this.ownerFence) {
          this.controlGeneration++;
        }
        this.ownerActive = nextOwnerActive;
        this.ownerFence = nextOwnerFence;
        this.ownerExpiresAt = nextOwnerExpiresAt;
        this.highestFence = Math.max(this.highestFence, nextOwnerFence);
        this.setStatus(
          nextOwnerActive
            ? `PiPilot: controlled (${selected})`
            : `PiPilot: synced (${selected})`,
        );
        return;
      }

      case "desktop_snapshot_request": {
        // 按需快照:hub 发现快照与事件流不连续时索要。
        // 绝不能走 resnapshot()——那会 newEpoch,清空重放环并摧毁租约。
        const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
        if (!requestId) return;
        if (!this.registered || !this.liveCtx()) {
          this.sendFrame({
            type: "desktop_snapshot_unavailable",
            requestId,
            reason: this.registered ? "stale_ctx" : "not_registered",
          });
          return;
        }
        this.sendSnapshot("hub request", requestId);
        return;
      }

      case "desktop_tree_request": {
        // 会话树不再依赖大快照里的可选 treeSummary 字段。长会话快照会降级,
        // 而树是用户主动打开时才需要的,按需生成既新鲜又不会拖累每次同步。
        const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
        const ctx = this.liveCtx();
        if (!requestId || !this.registered || !ctx || msg.epoch !== this.epoch) {
          if (requestId) {
            this.sendFrame({
              type: "desktop_tree_unavailable",
              requestId,
              reason: !this.registered
                ? "not_registered"
                : !ctx
                  ? "stale_ctx"
                  : "stale_epoch",
            });
          }
          return;
        }
        try {
          const rawTree = ctx.sessionManager.getTree();
          const tree = buildTreeSummary(rawTree);
          if (!tree) throw new Error("tree summary exceeds its byte budget");
          this.sendFrame({
            type: "desktop_tree",
            requestId,
            epoch: this.epoch,
            // 投影会丢噪音节点,leafId 必须重映射到摘要里真实存在的节点,
            // 否则生成一停(msg-meta custom 挂上尾巴)定位就落空。
            leafId: navigableLeafId(rawTree, ctx.sessionManager.getLeafId()),
            tree,
          });
        } catch (error) {
          this.sendFrame({
            type: "desktop_tree_unavailable",
            requestId,
            reason: error instanceof Error ? error.message : String(error),
          });
        }
        return;
      }

      case "desktop_ask_claimed": {
        // 手机确认卡片已经显示在前台。认领窗口(秒级)换成作答窗口(分钟级)——
        // 人读题选项要时间,但「手机在口袋里」不能让桌面干等那么久。
        const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
        const entry = this.pendingAsks.get(requestId);
        if (!entry || entry.claimed) return;
        entry.claimed = true;
        clearTimeout(entry.timer);
        entry.timer = setTimeout(
          () => this.settleAsk(requestId, undefined),
          this.config.askAnswerMs,
        );
        entry.timer.unref?.();
        this.notify("PiPilot: 问卷已转到手机作答", "info");
        return;
      }

      case "desktop_ask_result": {
        const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
        // 换过 epoch 说明会话已经不是发问那一个了,这份答案不能算。
        if (typeof msg.epoch === "string" && msg.epoch !== this.epoch) return;
        // 解析不出内容(空答案/形状不对)按回落处理,不能把空信封交给模型。
        this.settleAsk(requestId, formatAskAnswers(msg.answers));
        return;
      }

      case "desktop_ask_declined":
        // 手机主动交还(用户点了「在电脑上作答」),或 hub 发现没人在看。
        this.settleAsk(
          typeof msg.requestId === "string" ? msg.requestId : "",
          undefined,
        );
        return;

      case "desktop_resync_required":
        this.resnapshot(typeof msg.reason === "string" ? msg.reason : "hub requested resync");
        return;

      case "remote_command":
        this.queueRemoteCommand(msg);
        return;

      case "desktop_heartbeat_ack":
      case "desktop_ack":
      case "desktop_hello":
        return;
    }
  }

  private queueRemoteCommand(msg: JsonObject): void {
    const requestId = typeof msg.requestId === "string" ? msg.requestId : "";
    if (!requestId) return;
    const cached = this.commandResults.get(requestId);
    if (cached) {
      this.sendFrame(cached);
      return;
    }
    if (this.activeRequests.has(requestId)) return;
    if (this.commandDepth >= MAX_COMMAND_QUEUE) {
      this.sendCommandResult(requestId, false, undefined, "desktop command queue is full");
      return;
    }
    if (msg.epoch !== this.epoch) {
      this.sendCommandResult(requestId, false, undefined, "stale desktop session epoch");
      return;
    }
    if (typeof msg.fence !== "number" || !Number.isSafeInteger(msg.fence)) {
      this.sendCommandResult(requestId, false, undefined, "missing fencing token");
      return;
    }
    if (msg.fence < this.highestFence) {
      this.sendCommandResult(requestId, false, undefined, "stale fencing token");
      return;
    }
    if (!this.hasActiveOwner(msg.fence)) {
      this.sendCommandResult(requestId, false, undefined, "owner lease is not active or has expired");
      return;
    }
    if (!msg.command || typeof msg.command !== "object") {
      this.sendCommandResult(requestId, false, undefined, "invalid command");
      return;
    }

    this.highestFence = Math.max(this.highestFence, msg.fence);
    this.activeRequests.add(requestId);
    this.commandDepth++;
    const command = cloneForWire(msg.command) as RemoteCommand;
    const queuedEpoch = this.epoch;
    const queuedFence = msg.fence;
    const queuedGeneration = this.controlGeneration;
    this.commandChain = this.commandChain
      .then(async () => {
        const ctx = this.ctx;
        if (!this.active || !ctx) throw new Error("desktop runtime is shutting down");
        if (
          queuedEpoch !== this.epoch ||
          queuedGeneration !== this.controlGeneration ||
          !this.hasActiveOwner(queuedFence) ||
          queuedFence < this.highestFence
        ) {
          throw new Error("queued command has a stale owner lease");
        }
        const result = await executeRemoteCommand(command, {
          pi: this.pi,
          ctx,
          navigate: (entryId) => this.navigate(entryId, ctx),
          // ctx.compact() 不 await,失败只会走 onError 回调 ——
          // 不把它转给手机的话,手机会永远停在「正在压缩」。
          onCompactError: (message) =>
            this.emitEvent({ type: "system_message", level: "error", text: `压缩失败:${message}` }, ctx),
        });
        const delivery = (result as { delivery?: unknown } | undefined)?.delivery;
        if (delivery === "steer" || delivery === "followUp") {
          this.noteRemoteQueued(String(command.message), delivery, ctx);
        }
        return result;
      })
      .then(
        (data) => this.sendCommandResult(requestId, true, data),
        (error) =>
          this.sendCommandResult(
            requestId,
            false,
            undefined,
            error instanceof Error ? error.message : String(error),
          ),
      )
      .finally(() => {
        this.activeRequests.delete(requestId);
        this.commandDepth--;
      });
  }

  /**
   * 执行一次会话回退。
   *
   * 用缓存的命令上下文(远程命令自己的 ctx 上没有 `navigateTree`)。
   * 从没在电脑上跑过 `/pipilot-nav` 时缓存是空的,这时如实报错并提示用户
   * 在电脑上跑一次 —— 比悄悄失败或伪装成功要好。
   */
  private async navigate(entryId: string | undefined, ctx: ExtensionContext): Promise<unknown> {
    const cached = this.navCache?.get(this.boundSessionFile ?? "");
    if (!cached) {
      if (ctx.mode === "tui") {
        ctx.ui.notify(
          "手机请求回退会话:请先在这里执行一次 /pipilot-undo 以启用远程回退",
          "warning",
        );
      }
      throw new Error(
        "rollback needs the desktop command context; run /pipilot-undo once on the computer",
      );
    }
    const result = await runNavigate(navRuntimeFor(cached), entryId);
    if (!result.ok) throw new Error(result.error ?? "rollback was cancelled");
    return result;
  }

  /** 回退结果广播给手机:两端都靠随后的 `session_tree` 事件收敛。 */
  emitNavResult(result: NavResult, ctx: ExtensionContext): void {
    this.emitEvent(
      {
        type: "pipilot_nav_result",
        ok: result.ok,
        ...(result.editorText !== undefined ? { editorText: result.editorText } : {}),
        ...(result.error !== undefined ? { error: result.error } : {}),
      },
      ctx,
    );
    this.snapshot(ctx);
  }

  private sendCommandResult(
    requestId: string,
    success: boolean,
    data?: unknown,
    error?: string,
  ): void {
    const result: JsonObject = {
      type: "remote_result",
      requestId,
      success,
      ...(data !== undefined ? { data } : {}),
      ...(error ? { error } : {}),
    };
    this.commandResults.set(requestId, result);
    while (this.commandResults.size > MAX_COMMAND_RESULTS) {
      const oldest = this.commandResults.keys().next().value as string | undefined;
      if (!oldest) break;
      this.commandResults.delete(oldest);
    }
    this.sendFrame(result);
  }

  private sendRegistration(): void {
    const ctx = this.liveCtx();
    if (!ctx) return;
    const snapshot = this.captureSnapshot();
    if (!snapshot) return;
    this.sendFrame(
      {
        type: "desktop_register",
        source: {
          sourceId: this.sourceId,
          // 目录名 + git 分支(非 git 仓库就只有目录名)。PID 对人是噪音。
          label:
            this.config.label ?? sourceLabel(ctx.cwd),
          cwd: ctx.cwd,
          sessionId: ctx.sessionManager.getSessionId(),
          sessionFile: ctx.sessionManager.getSessionFile(),
          sessionName: ctx.sessionManager.getSessionName(),
          capabilities: [...SAFE_REMOTE_COMMANDS, LIVE_TREE_CAPABILITY, LIVE_ASK_CAPABILITY],
        },
        snapshot,
      },
      MAX_SNAPSHOT_BYTES,
    );
  }

  private sendSnapshot(reason: string, requestId?: string): void {
    if (!this.registered) return;
    // 顺序是关键:先把 25ms/100ms 合批计时器排空(各自 ++seq),再取快照,
    // 这样 baseSeq 恰好等于线上最后一个事件——既不留洞也不重复。
    this.flushCoalesced();
    const snapshot = this.captureSnapshot();
    if (!snapshot) return;
    this.lastSnapshotAt = Date.now();
    this.lastSnapshotSeq = this.seq;
    this.sendFrame(
      {
        type: "desktop_snapshot",
        reason,
        ...(requestId ? { requestId } : {}),
        snapshot,
      },
      MAX_SNAPSHOT_BYTES,
    );
  }

  private captureSnapshot(): JsonObject | undefined {
    const ctx = this.liveCtx();
    if (!ctx) return undefined;
    const branch = ctx.sessionManager.getBranch();
    // branch 本身可能超过 MAX_CAPTURE_BYTES(64MB),直接 clone 会抛出未捕获
    // 异常导致 pi 退出。逐步截断最老的消息再重试;截断时设置 snapshotTruncated
    // 让客户端知道历史不完整。
    let entries: JsonObject[];
    let branchTruncated = false;
    {
      let working = branch;
      for (;;) {
        try {
          entries = cloneForWire(working, MAX_CAPTURE_BYTES) as unknown as JsonObject[];
          break;
        } catch {
          if (working.length <= 1) {
            entries = [];
            branchTruncated = true;
            break;
          }
          const removeCount = Math.max(1, Math.floor(working.length / 4));
          working = working.slice(removeCount);
          branchTruncated = true;
        }
      }
    }
    // 历史回放补时长:assistant entry 附上持久化过的 thinkingDurationMs。
    this.attachThinkingDurations(entries);
    const models = ctx.modelRegistry.getAvailable().map((model) => serializeModel(model));
    const contextUsage = ctx.getContextUsage();
    const state: JsonObject = {
      model: serializeModel(ctx.model),
      thinkingLevel: this.pi.getThinkingLevel(),
      isStreaming: !ctx.isIdle(),
      isCompacting: this.compacting,
      steeringMode: "one-at-a-time",
      followUpMode: "one-at-a-time",
      sessionFile: ctx.sessionManager.getSessionFile() ?? null,
      sessionId: ctx.sessionManager.getSessionId(),
      sessionName: ctx.sessionManager.getSessionName() ?? null,
      cwd: ctx.cwd,
      // 扩展 API 不暴露 auto-compaction 状态,发 null 让客户端显示「未知」
      autoCompactionEnabled: null,
      messageCount: entries.length,
      pendingMessageCount: ctx.hasPendingMessages() ? 1 : 0,
      contextUsage: contextUsage ?? null,
    };
    if (branchTruncated) state.snapshotTruncated = true;

    let stats: JsonObject | undefined;
    try {
      stats = computeSessionStats(branch, contextUsage);
    } catch {
      stats = undefined;
    }
    let commands: JsonObject[] | undefined;
    try {
      commands = this.pi.getCommands().map((command) => ({
        name: command.name,
        description: command.description ?? null,
        source: command.source,
      }));
      // pi 的 22 个内置斜杠命令住在 dist/core/slash-commands.js,只给交互模式的
      // 自动补全用,getCommands() 拿不到 —— 所以手机上以前根本看不见 /compact,
      // 硬敲进去也只会当普通文本发给模型。
      //
      // 只补 compact 一个:model / thinking / name / tree 在 App 里已经有原生入口,
      // settings / hotkeys / export / share / login / quit 是电脑本地的事,
      // new / resume / fork / clone 永不开放 —— 那会换掉人正在用的会话。
      if (!commands.some((command) => command.name === BUILTIN_COMPACT.name)) {
        commands.push({ ...BUILTIN_COMPACT });
      }
    } catch {
      commands = undefined;
    }
    const makeSnapshot = (): JsonObject => ({
      epoch: this.epoch,
      baseSeq: this.seq,
      capturedAt: Date.now(),
      state,
      entries,
      leafId: ctx.sessionManager.getLeafId(),
      models,
      thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
      ...(this.inFlightMessage ? { inFlightMessage: this.inFlightMessage } : {}),
      ...(stats ? { stats } : {}),
      ...(commands ? { commands } : {}),
    });

    // 会话树走 desktop_tree_request 独立按需读取,不再塞进每一份快照。
    // 快照超限时先丢可重建的命令列表,再截断最老的历史 entries。
    let snapshot = makeSnapshot();
    for (;;) {
      try {
        encodeForWire(snapshot, MAX_SNAPSHOT_BYTES);
        return snapshot;
      } catch {
        if (commands) {
          commands = undefined;
        } else if (entries.length > 1) {
          const removeCount = Math.max(1, Math.floor(entries.length / 4));
          entries = entries.slice(removeCount);
          state.snapshotTruncated = true;
          state.messageCount = entries.length;
        } else {
          break;
        }
        snapshot = makeSnapshot();
      }
    }
    encodeForWire(snapshot, MAX_SNAPSHOT_BYTES);
    return snapshot;
  }

  private sendEvent(event: unknown): void {
    if (!this.registered) return;
    try {
      const cloned = cloneForWire(event) as JsonObject;
      this.sendFrame({
        type: "desktop_event",
        epoch: this.epoch,
        seq: ++this.seq,
        event: cloned,
      });
    } catch {
      this.resnapshot("event serialization failed");
    }
  }

  private sendFrame(frame: JsonObject, maxBytes?: number): boolean {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    if (socket.bufferedAmount > MAX_SOCKET_BUFFER) {
      socket.close(1013, "relay backpressure");
      return false;
    }
    try {
      socket.send(encodeForWire(frame, maxBytes));
      return true;
    } catch {
      socket.close(1011, "relay serialization failure");
      return false;
    }
  }

  private resnapshot(_reason: string): void {
    if (!this.active || !this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.newEpoch();
    this.registered = true;
    this.sendSnapshot("epoch reset");
  }

  private newEpoch(): void {
    this.cancelCoalesced();
    this.epoch = crypto.randomUUID();
    this.seq = 0;
    this.controlGeneration++;
    this.ownerActive = false;
    this.ownerFence = 0;
    this.ownerExpiresAt = 0;
    this.commandResults.clear();
    this.highestFence = 0;
  }

  private scheduleReconnect(): void {
    if (!this.active || this.reconnectTimer) return;
    const base = Math.min(
      this.config.reconnectMaxMs,
      this.config.reconnectMinMs * 2 ** this.reconnectAttempt++,
    );
    const delay = Math.round(base * (0.8 + Math.random() * 0.4));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
    this.reconnectTimer.unref();
  }

  private startHeartbeat(): void {
    this.clearHeartbeat();
    this.heartbeatTimer = setInterval(
      () => this.sendFrame({ type: "desktop_heartbeat", t: Date.now() }),
      HEARTBEAT_MS,
    );
    this.heartbeatTimer.unref();
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = undefined;
  }

  private flushMessageUpdate(): void {
    if (this.messageTimer) clearTimeout(this.messageTimer);
    this.messageTimer = undefined;
    const pending = this.pendingMessageUpdate;
    this.pendingMessageUpdate = undefined;
    if (pending) this.sendEvent(pending);
  }

  private flushToolUpdates(): void {
    if (this.toolTimer) clearTimeout(this.toolTimer);
    this.toolTimer = undefined;
    for (const event of this.pendingToolUpdates.values()) this.sendEvent(event);
    this.pendingToolUpdates.clear();
  }

  private flushCoalesced(): void {
    this.flushMessageUpdate();
    this.flushToolUpdates();
  }

  private cancelCoalesced(): void {
    if (this.messageTimer) clearTimeout(this.messageTimer);
    if (this.toolTimer) clearTimeout(this.toolTimer);
    this.messageTimer = undefined;
    this.toolTimer = undefined;
    this.pendingMessageUpdate = undefined;
    this.pendingToolUpdates.clear();
  }

  private stopInternal(clearStatus: boolean): void {
    this.active = false;
    this.registered = false;
    // 在途问卷必须放行,否则那个 await 永远不返回,整个 agent 回合卡死。
    this.failPendingAsks();
    this.selectedClients = 0;
    this.controlGeneration++;
    this.ownerActive = false;
    this.ownerFence = 0;
    this.ownerExpiresAt = 0;
    this.streaming = false;
    this.clearSnapshotTimer();
    this.cancelCoalesced();
    this.clearHeartbeat();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    const socket = this.socket;
    this.socket = undefined;
    socket?.close(1000, "desktop runtime stopped");
    if (clearStatus) this.setStatus(undefined);
    this.ctx = undefined;
  }

  /**
   * 拦下 `ask_user_question`,把问卷转给手机作答。
   *
   * 返回 `undefined` = 不拦,插件照常在电脑上弹它那套完整问卷(标签页、备注、
   * 预览、折叠、九种语言)。所以所有「转不过去」的情形都走这条路,手机端的
   * 这套东西永远只是加法,不会让桌面变差。
   *
   * 返回 `{block, reason}` = 插件的 `execute` 整个不跑,模型直接收到手机上的
   * 选择。注意 reason 会被 pi 包进错误信封(见 ASK_ANSWER_HEADER)。
   */
  async interceptAsk(
    event: { toolName: string; toolCallId: string; input: unknown },
    ctx: ExtensionContext,
  ): Promise<{ block: true; reason: string } | undefined> {
    if (event.toolName !== ASK_TOOL_NAME) return undefined;
    if (!this.isCurrent(ctx) || !this.registered) return undefined;
    // 没有手机在看这个源:不拦。这是「桌面不许因为装了 PiPilot 而变差」的保证。
    if (this.selectedClients <= 0) return undefined;
    const questions = normalizeAskQuestions(event.input);
    if (!questions) return undefined;

    const requestId = `ask:${crypto.randomUUID()}`;
    const sent = this.sendFrame(
      {
        type: "desktop_ask_request",
        requestId,
        epoch: this.epoch,
        toolCallId: event.toolCallId,
        questions,
      },
      MAX_SNAPSHOT_BYTES,
    );
    if (!sent) return undefined;

    const answer = await new Promise<string | undefined>((resolve) => {
      // 先给认领窗口:手机得先确认「卡片在前台、有人在看」。
      const timer = setTimeout(
        () => this.settleAsk(requestId, undefined),
        this.config.askClaimMs,
      );
      timer.unref?.();
      this.pendingAsks.set(requestId, { resolve, timer, claimed: false });
    });

    if (answer === undefined) {
      // 撤掉手机上可能已经画出来的卡片,免得它停在一个已经由电脑接手的问卷上。
      this.sendFrame({ type: "desktop_ask_cancel", requestId });
      return undefined;
    }
    return { block: true, reason: answer };
  }

  private settleAsk(requestId: string, answer: string | undefined): void {
    const entry = this.pendingAsks.get(requestId);
    if (!entry) return;
    this.pendingAsks.delete(requestId);
    clearTimeout(entry.timer);
    entry.resolve(answer);
  }

  private failPendingAsks(): void {
    for (const requestId of [...this.pendingAsks.keys()]) {
      this.settleAsk(requestId, undefined);
    }
  }

  private notify(message: string, level: "info" | "warning" | "error"): void {
    // ctx 会在会话替换/reload 之后失效,那时读它的任何 getter 都抛 ——
    // 而这个方法是被 socket 回调驱动的,可能正好落在之后。
    try {
      this.ctx?.ui.notify(message, level);
    } catch {
      // stale ctx after session replacement; nothing to notify
    }
  }

  private setStatus(text: string | undefined): void {
    // The captured ctx goes stale after session replacement/reload; accessing
    // any of its getters (including ctx.ui) then throws. Async socket/timer
    // callbacks can run after that, so swallow the stale-ctx error here.
    try {
      this.ctx?.ui.setStatus("pipilot-sync", text);
    } catch {
      // stale ctx after session replacement; nothing to update
    }
  }

  private liveCtx(): ExtensionContext | undefined {
    const ctx = this.ctx;
    if (!ctx) return undefined;
    try {
      void ctx.cwd; // any getter throws when the ctx is stale
      return ctx;
    } catch {
      return undefined;
    }
  }

  private hasActiveOwner(fence: number): boolean {
    return (
      this.ownerActive &&
      this.ownerFence === fence &&
      this.ownerExpiresAt > Date.now()
    );
  }

  /**
   * 这个 ctx 属于当前会话吗?
   *
   * **不能用对象身份比。** pi 的 `ExtensionRunner.emit()` 每次都
   * `createContext()` 新建一个对象(runner.js:570),所以 `this.ctx === ctx`
   * 只在 `session_start` 那一次成立 —— 用身份比等于把之后的**每一个**事件、
   * 每一次快照、每一次流式标志全部静默丢掉,桌面源看起来在线却永远不更新。
   *
   * 真正要判的是"这个 ctx 指向的还是我们绑定的那个会话"。顺便把 `this.ctx`
   * 刷新成最新的活 ctx,免得后续异步发送用到一个已经失效的旧对象。
   */
  private isCurrent(ctx: ExtensionContext): boolean {
    if (!this.active || !this.ctx) return false;
    if (this.ctx === ctx) return true;
    try {
      const file = ctx.sessionManager.getSessionFile();
      if (file !== this.boundSessionFile) return false;
      this.ctx = ctx;
      return true;
    } catch {
      // 陈旧 ctx 的 getter 会抛 assertActive()
      return false;
    }
  }

  /** 与 `isCurrent` 同源的判据,给 `stop()` 用。 */
  private isBound(ctx: ExtensionContext): boolean {
    if (this.ctx === ctx) return true;
    try {
      return ctx.sessionManager.getSessionFile() === this.boundSessionFile;
    } catch {
      return false;
    }
  }
}
