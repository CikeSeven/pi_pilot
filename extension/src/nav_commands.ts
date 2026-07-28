import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

/**
 * 会话回退。
 *
 * pi 的 RPC 协议里**没有** `navigate_tree` 命令(只读的 `get_tree` 和另开文件的
 * `fork`),唯一能原地移动 leaf 的入口是 `ExtensionCommandContext.navigateTree`。
 * 所以我们把它包成扩展命令:
 *
 * - headless(`pi --mode rpc`):hub 把 `navigate_tree` 翻译成
 *   `prompt "/pipilot-nav <entryId>"`。RPC 的 `prompt` 默认展开扩展命令,
 *   而扩展在 rpc 模式同样会被加载并绑定 `navigateTree`。
 * - 桌面 TUI:远程命令拿到的是普通 `ExtensionContext`(**没有** `navigateTree`),
 *   所以这里缓存一次命令上下文,远程回退直接复用它。
 *
 * `navigateTree` 自己**不会中断正在进行的回合** —— 它直接重写
 * `agent.state.messages`。所以每次调用前必须先 `abort()` 再 `waitForIdle()`,
 * 否则会在一个活着的回合底下抽走上下文。
 */

export interface NavResult {
  ok: boolean;
  /** 目标是用户消息时,pi 会把原文回填给调用方(TUI 里就是回到输入框)。 */
  editorText?: string;
  cancelled?: boolean;
  error?: string;
}

/// pi 的 `ReadonlySessionManager.getTree()` 返回 `{ entry, children }`。
/// **不要**照 relay 发给手机的扁平形态来写 —— 那是 `summarizeTreeNode` 压平之后的。
export interface TreeNodeLike {
  entry?: { id?: unknown; type?: unknown; message?: { role?: unknown } };
  children?: unknown;
}

/** 解析 `/pipilot-nav <entryId>` 的参数。空参数表示"撤销上一轮"。 */
export function parseNavArgs(args: string): { entryId?: string } {
  const trimmed = args.trim();
  if (!trimmed) return {};
  // 只取第一个 token:entry id 里不会有空格
  const [entryId] = trimmed.split(/\s+/);
  return { entryId };
}

/**
 * 「撤销上一轮」的目标 = 当前分支上**最后一条用户消息**。
 *
 * 会话文件是 append-only、没有 undo,所以撤销的实现是把 leaf 移回那条用户消息
 * 的父节点 —— pi 会顺带把消息原文回填给调用方,正好等于"内容回到输入框"。
 */
export function undoTargetId(
  tree: readonly TreeNodeLike[] | undefined,
  leafId: string | undefined,
): string | undefined {
  if (!tree || !leafId) return undefined;
  const path = pathToLeaf(tree, leafId);
  if (!path) return undefined;
  for (let i = path.length - 1; i >= 0; i--) {
    const entry = path[i]?.entry;
    if (
      entry?.type === "message" &&
      entry.message?.role === "user" &&
      typeof entry.id === "string"
    ) {
      return entry.id;
    }
  }
  return undefined;
}

function pathToLeaf(
  nodes: readonly TreeNodeLike[],
  leafId: string,
): TreeNodeLike[] | undefined {
  for (const node of nodes) {
    if (node.entry?.id === leafId) return [node];
    const children = Array.isArray(node.children) ? (node.children as TreeNodeLike[]) : [];
    const below = pathToLeaf(children, leafId);
    if (below) return [node, ...below];
  }
  return undefined;
}

export interface NavRuntime {
  abort(): void;
  waitForIdle(): Promise<void>;
  navigateTree(
    targetId: string,
    options?: { label?: string },
  ): Promise<{ cancelled?: boolean }>;
  getTree(): readonly TreeNodeLike[];
  getLeafId(): string | undefined;
}

/** 执行一次回退。`entryId` 为空表示撤销上一轮。 */
export async function runNavigate(
  runtime: NavRuntime,
  entryId: string | undefined,
): Promise<NavResult> {
  // 先确认有得撤:没有目标就绝不能白白打断一个正在跑的回合
  if (!entryId && !undoTargetId(runtime.getTree(), runtime.getLeafId())) {
    return { ok: false, error: "没有可撤销的回合" };
  }
  // 整段都要包进 try:陈旧上下文在 abort()/waitForIdle() 这两步就会抛
  // assertActive(),漏在外面会变成命令链上一个裸 rejection。
  try {
    // navigateTree 不会自己中断 —— 它直接重写 agent.state.messages,
    // 必须先停下正在跑的回合。
    runtime.abort();
    await runtime.waitForIdle();
    // **中断之后重新读树**:等待期间 pi 会落盘部分助手消息和排队消息,
    // 用中断前的快照定位会多丢一截用户没要求丢的内容。
    const target = entryId ?? undoTargetId(runtime.getTree(), runtime.getLeafId());
    if (!target) return { ok: false, error: "没有可撤销的回合" };
    const result = await runtime.navigateTree(target, { label: "PiPilot" });
    if (result?.cancelled === true) return { ok: false, cancelled: true };
    const editorText = (result as { editorText?: unknown }).editorText;
    return {
      ok: true,
      ...(typeof editorText === "string" ? { editorText } : {}),
    };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

/**
 * 缓存最近一次命令上下文。
 *
 * 远程命令(手机发来的)拿到的是普通 `ExtensionContext`,上面没有 `navigateTree`。
 * 用户在电脑上跑过一次 `/pipilot-nav` 之后,这里就有了一个可用的命令上下文;
 * 冷启动(从没跑过)时回退到"把命令写进输入框请用户按回车"。
 */
export class NavCommandContextCache {
  private cached: ExtensionCommandContext | undefined;
  private cachedSessionFile: string | undefined;

  remember(ctx: ExtensionCommandContext): void {
    this.cached = ctx;
    this.cachedSessionFile = readSessionFile(ctx);
  }

  /** 会话换了(switch / fork / new):缓存的上下文属于上一个 runner,必须丢掉。 */
  invalidate(): void {
    this.cached = undefined;
    this.cachedSessionFile = undefined;
  }

  /**
   * 取一个**仍然属于 `expectedSessionFile` 且没有失效**的上下文。
   *
   * 陈旧上下文的 getter 会抛 `assertActive()`;更糟的是它可能仍然指向已经
   * 被替换掉的会话 —— 那样回退会改错会话。这里两条都挡。
   */
  get(expectedSessionFile?: string): ExtensionCommandContext | undefined {
    const ctx = this.cached;
    if (!ctx) return undefined;
    const current = readSessionFile(ctx);
    if (current === undefined) {
      // getter 抛了 = 上下文已失效
      this.invalidate();
      return undefined;
    }
    if (current !== this.cachedSessionFile) {
      this.invalidate();
      return undefined;
    }
    if (expectedSessionFile !== undefined && current !== expectedSessionFile) {
      return undefined;
    }
    return ctx;
  }

  get available(): boolean {
    return this.get() !== undefined;
  }
}

function readSessionFile(ctx: ExtensionCommandContext): string | undefined {
  try {
    return ctx.sessionManager.getSessionFile() ?? "";
  } catch {
    return undefined;
  }
}

export function navRuntimeFor(ctx: ExtensionCommandContext): NavRuntime {
  const anyCtx = ctx as unknown as {
    abort?: () => void;
    waitForIdle?: () => Promise<void>;
    navigateTree: NavRuntime["navigateTree"];
    sessionManager?: {
      getTree?: () => readonly TreeNodeLike[];
      getLeafId?: () => string | null;
    };
  };
  return {
    abort: () => anyCtx.abort?.(),
    waitForIdle: async () => {
      await anyCtx.waitForIdle?.();
    },
    navigateTree: (targetId, options) => anyCtx.navigateTree(targetId, options),
    getTree: () => anyCtx.sessionManager?.getTree?.() ?? [],
    getLeafId: () => anyCtx.sessionManager?.getLeafId?.() ?? undefined,
  };
}

/** 注册 `/pipilot-nav` 与 `/pipilot-undo`,并缓存命令上下文供远程回退复用。 */
export function registerNavCommands(
  pi: ExtensionAPI,
  cache: NavCommandContextCache,
  onResult?: (result: NavResult, ctx: ExtensionContext) => void,
): void {
  const run = async (args: string, ctx: ExtensionCommandContext): Promise<void> => {
    cache.remember(ctx);
    const { entryId } = parseNavArgs(args);
    const result = await runNavigate(navRuntimeFor(ctx), entryId);
    onResult?.(result, ctx);
    if (ctx.mode === "tui" && !result.ok && result.error) {
      ctx.ui.notify(result.error, "error");
    }
  };

  pi.registerCommand("pipilot-nav", {
    description: "PiPilot: 回到会话树上的某个节点(参数为 entry id)",
    handler: (args, ctx) => run(args, ctx as ExtensionCommandContext),
  });

  pi.registerCommand("pipilot-undo", {
    description: "PiPilot: 撤销上一轮(回到最后一条用户消息)",
    handler: (_args, ctx) => run("", ctx as ExtensionCommandContext),
  });
}
