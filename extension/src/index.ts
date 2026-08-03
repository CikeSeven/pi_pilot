import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { AgentSession, ExtensionRunner } from "@earendil-works/pi-coding-agent";
import { loadRelayConfig, RELAY_CONFIG_PATH } from "./config.js";
import { NavCommandContextCache, registerNavCommands } from "./nav_commands.js";
import { abortRemoteOperation } from "./remote_commands.js";
import { DesktopRelay, compactEventFrame, sessionTreeFrame } from "./relay.js";

/**
 * 给普通事件 ctx 补上 PiPilot 远程控制需要的会话级能力。
 *
 * `navigateTree` 和 `abortCompaction` 都是 AgentSession 的公开能力,但 pi
 * 没把它们放进普通 ExtensionContext。手机命令来自 WebSocket,只能拿到
 * 普通 ctx,所以在宿主创建 ctx 时补上受 assertActive 保护的薄委托。
 */
function patchRunnerContext(): void {
  try {
    const proto = (ExtensionRunner as unknown as { prototype?: Record<string, unknown> })
      ?.prototype;
    if (!proto || typeof proto.createContext !== "function") return;
    if ((proto.createContext as { __pipilotContextPatched?: boolean }).__pipilotContextPatched) {
      return;
    }
    const original = proto.createContext as (this: unknown) => Record<string, unknown>;
    const patched = function (this: {
      assertActive?: () => void;
      navigateTreeHandler?: (
        targetId: string,
        options?: unknown,
      ) => Promise<unknown>;
      __pipilotAbortCompaction?: () => void;
      __pipilotIsCompacting?: () => boolean;
    }): Record<string, unknown> {
      const ctx = original.call(this);
      const runner = this;
      if (
        ctx &&
        typeof ctx.navigateTree !== "function" &&
        typeof runner.navigateTreeHandler === "function"
      ) {
        ctx.navigateTree = (targetId: string, options?: unknown) => {
          runner.assertActive?.();
          return runner.navigateTreeHandler!(targetId, options);
        };
      }
      if (ctx && typeof runner.__pipilotAbortCompaction === "function") {
        ctx.abortCompaction = () => {
          runner.assertActive?.();
          runner.__pipilotAbortCompaction!();
        };
        ctx.isCompacting = () => {
          runner.assertActive?.();
          return runner.__pipilotIsCompacting?.() === true;
        };
      }
      return ctx;
    };
    (patched as { __pipilotContextPatched?: boolean }).__pipilotContextPatched = true;
    proto.createContext = patched;
  } catch {
    // 补丁失败就保持原样;relay 会对回退走缓存兜底,压缩中断则明确报不可用。
  }
}

/** 把当前 AgentSession 的压缩控制器绑定到它自己的 ExtensionRunner。 */
function patchAgentSessionCompactionControl(): void {
  try {
    const proto = (AgentSession as unknown as { prototype?: Record<string, unknown> })
      ?.prototype;
    if (!proto || typeof proto._bindExtensionCore !== "function") return;
    if (
      (proto._bindExtensionCore as { __pipilotCompactionPatched?: boolean })
        .__pipilotCompactionPatched
    ) {
      return;
    }
    const original = proto._bindExtensionCore as (
      this: unknown,
      runner: unknown,
    ) => void;
    const patched = function (
      this: { abortCompaction?: () => void; isCompacting?: boolean },
      runner: {
        __pipilotAbortCompaction?: () => void;
        __pipilotIsCompacting?: () => boolean;
      },
    ): void {
      original.call(this, runner);
      runner.__pipilotAbortCompaction = () => this.abortCompaction?.();
      runner.__pipilotIsCompacting = () => this.isCompacting === true;
    };
    (patched as { __pipilotCompactionPatched?: boolean }).__pipilotCompactionPatched = true;
    proto._bindExtensionCore = patched;
  } catch {
    // 宿主版本没有对应公开控制器时保持兼容,不阻止扩展启动。
  }
}

patchAgentSessionCompactionControl();
patchRunnerContext();

/**
 * 给 agent_end 帧补上 willRetry / aborted 标记。
 *
 * pi 给 session 订阅者的 agent_end 带 willRetry(agent-session.js 的
 * _willRetryAfterAgentEnd),但扩展事件只有 messages。手机/Bridge/原生
 * watcher 都靠这两个标记区分三种结束:
 *  - willRetry:API 报错后还要自动重试 —— 不能当完成,否则会先弹
 *    「任务完成」再看到重试的 agent_start。
 *  - aborted:用户中断(电脑端 Esc / 手机端停止)—— 轮次确实结束,
 *    但不该弹完成通知。
 *
 * 这里按 pi 的同一规则判:看 messages 里最后一个 assistant 的 stopReason。
 * willRetry 判偏(重试被禁用/次数耗尽/错误不可重试)也无害:不重试时
 * agent_settled 紧随其后,由它负责收口。
 */
export function agentEndFrame(event: unknown): unknown {
  const source = (event ?? {}) as { messages?: unknown };
  const messages = source.messages;
  if (!Array.isArray(messages)) return event;
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i] as { role?: unknown; stopReason?: unknown } | null;
    if (msg?.role === "assistant") {
      if (msg.stopReason === "error") return { ...source, willRetry: true };
      if (msg.stopReason === "aborted") return { ...source, aborted: true };
      return event;
    }
  }
  return event;
}

export default function pipilotDesktopRelay(pi: ExtensionAPI): void {
  let relay: DesktopRelay | undefined;
  // 远程回退要用命令上下文(普通 ctx 上没有 navigateTree),这里缓存一次
  const navCache = new NavCommandContextCache();

  pi.on("session_start", (_event, ctx) => {
    navCache.invalidate();
    if (ctx.mode !== "tui") return;
    // A previous session's relay may still be running with a now-stale ctx.
    relay?.dispose();
    relay = undefined;
    let config;
    try {
      config = loadRelayConfig();
    } catch (error) {
      ctx.ui.setStatus("pipilot-sync", "PiPilot: config error");
      ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
      return;
    }
    if (!config) {
      ctx.ui.setStatus("pipilot-sync", "PiPilot: not configured");
      return;
    }
    relay = new DesktopRelay(pi, config, navCache);
    relay.start(ctx);
  });

  pi.on("session_shutdown", (event, ctx) => {
    relay?.emitBoundary(event, ctx);
    relay?.flushThinkingDurations();
    relay?.stop(ctx);
    relay = undefined;
    if (ctx.mode === "tui") ctx.ui.setStatus("pipilot-sync", undefined);
  });

  const emit = (event: unknown, ctx: ExtensionContext) => relay?.emitEvent(event, ctx);
  const boundary = (event: unknown, ctx: ExtensionContext) => relay?.emitBoundary(event, ctx);
  const emitAndSnapshot = (event: unknown, ctx: ExtensionContext) => {
    relay?.emitBoundary(event, ctx);
    relay?.snapshot(ctx);
  };

  pi.on("agent_start", (event, ctx) => {
    relay?.setStreaming(true, ctx);
    relay?.emitBoundary(event, ctx);
  });
  pi.on("agent_end", (event, ctx) => {
    // 一轮结束(含被中断):pi 把未发送的排队消息回填到电脑端输入框,
    // 镜像必须跟着清空,否则手机会一直显示一批不存在的待发消息。
    relay?.noteAborted(ctx);
    relay?.emitBoundary(agentEndFrame(event), ctx);
  });
  pi.on("agent_settled", (event, ctx) => {
    relay?.setStreaming(false, ctx);
    // 自动压缩/失败/中断都必须在 settled 时收口。成功路径会更早收到
    // session_compact;这里负责补上「没有 session_compact」的失败分支,
    // 并保证手机收到明确的中断事件而不是只看到标志突然消失。
    relay?.finishCompaction(ctx, { aborted: true });
    // 一轮彻底跑完,队列必然清空 —— 镜像跟着归零,免得越积越多
    relay?.clearQueueMirror(ctx);
    relay?.emitBoundary(event, ctx);
    relay?.snapshot(ctx);
  });
  pi.on("turn_start", boundary);
  pi.on("turn_end", boundary);
  pi.on("message_start", boundary);
  pi.on("message_update", (event, ctx) => relay?.emitMessageUpdate(event, ctx));
  pi.on("message_end", (event, ctx) => relay?.emitMessageEnd(event, ctx));
  pi.on("tool_execution_start", boundary);
  pi.on("tool_execution_update", (event, ctx) => relay?.emitToolUpdate(event, ctx));
  pi.on("tool_execution_end", (event, ctx) => relay?.emitToolEnd(event, ctx));
  pi.on("model_select", emitAndSnapshot);
  pi.on("thinking_level_select", emitAndSnapshot);
  pi.on("session_info_changed", emitAndSnapshot);
  pi.on("session_tree", (event, ctx) => {
    // pi 原生字段是 newLeafId,手机端协议认 leafId —— 不归一化手机端
    // 永远读不到 leaf,回退后消息列表不会重置重建(旧分支消息一直挂着)。
    relay?.emitBoundary(sessionTreeFrame(event), ctx);
    relay?.snapshot(ctx);
  });
  pi.on("session_before_compact", (event, ctx) => {
    relay?.setCompacting(true, ctx);
    // 必须线框化:原始事件带整段 branchEntries + AbortSignal,超预算
    // 会让 sendEvent 静默丢事件并重置 epoch(详见 compactEventFrame)。
    relay?.emitBoundary(compactEventFrame(event), ctx);
    relay?.snapshot(ctx);
  });
  pi.on("session_compact", (event, ctx) => {
    relay?.setCompacting(false, ctx);
    relay?.emitBoundary(compactEventFrame(event), ctx);
    relay?.snapshot(ctx);
  });
  // 会话切换/分支操作:先发提示帧,手机才知道随后的离线是"切换"不是"掉线"
  // 会话即将变化:发提示帧,并作废缓存的命令上下文 ——
  // 它属于旧 runner,拿它做回退会改错会话(或直接抛 assertActive)。
  pi.on("session_before_switch", (event, ctx) => {
    navCache.invalidate();
    relay?.emitSessionTransition("switch", ctx);
    relay?.emitBoundary(event, ctx);
  });
  pi.on("session_before_fork", (event, ctx) => {
    navCache.invalidate();
    relay?.emitSessionTransition("fork", ctx);
    relay?.emitBoundary(event, ctx);
  });
  pi.on("session_before_tree", (event, ctx) => {
    relay?.emitSessionTransition("tree", ctx);
    relay?.emitBoundary(event, ctx);
  });
  pi.on("input", emit);
  pi.on("user_bash", emit);

  // ask_user_question 拦截。
  //
  // 第三方插件 @juicesharp/rpiv-ask-user-question 把问卷画在 TUI 覆盖层
  // (`ctx.ui.custom()`),不走 pi 的 extension_ui_request 协议,所以手机上只看得到
  // 一个转不完的圈。它又是严格单向的(全仓两处 emit、零处 on),没有任何可编程
  // 应答入口;同名注册也顶不掉它(runner.js 是先注册者赢,而它在 settings.json 里
  // 排在 PiPilot 之前)。所以唯一的口子是在它的 execute 跑起来之前拦下整次调用。
  //
  // 钩子里 await 是安全的:agent-loop 的 beforeToolCall 本就是被 await 的且无超时,
  // 插件自己也同样卡在等人敲键盘。
  pi.on("tool_call", async (event, ctx) => await relay?.interceptAsk(event, ctx));

  // working-activity 插件(TUI Working 行)的纯文本状态实时镜像到手机。
  // 插件每个 render 分支把纯文本状态 emit 到 pi.events 总线,这里转发给
  // bridge 广播 —— 手机灵动岛显示的和桌面 Working 行是同一份内容,
  // 不再是手机端自己从 items 推导的二手状态。
  pi.events.on("working-activity:status", (data) => {
    const text =
      data && typeof data === "object"
        ? ((data as { text?: string | null }).text ?? null)
        : null;
    relay?.sendActivityStatus(text);
  });

  registerNavCommands(pi, navCache, (result, ctx) => {
    relay?.emitNavResult(result, ctx);
  });

  // Bridge 给 headless RPC 的 abort 会翻译到这个内部命令。RPC 原生 abort()
  // 只停 agent,不会停独立的压缩控制器;这里与桌面 Esc 使用同一能力。
  pi.registerCommand("pipilot-abort", {
    description: "PiPilot: 中断当前生成或压缩",
    handler: async (_args, ctx) => {
      await abortRemoteOperation(
        ctx as ExtensionContext & {
          abortCompaction?: () => void;
          isCompacting?: () => boolean;
        },
      );
    },
  });

  pi.registerCommand("pipilot", {
    description: "Show PiPilot desktop relay status",
    handler: async (_args, ctx) => {
      // 补丁(见文件顶部)生效后远程回退开箱即用,这里只是兜底激活:
      // 老 pi 或非 jiti 加载导致补丁失效时,navCache 老路径还需要一次
      // 命令上下文。/pipilot 是**无副作用**的状态命令,适合当这个入口。
      navCache.remember(ctx as ExtensionCommandContext);
      if (ctx.mode !== "tui") return;
      ctx.ui.notify(
        relay
          ? `PiPilot desktop relay is active. Config: ${RELAY_CONFIG_PATH}`
          : `PiPilot desktop relay is inactive. Config: ${RELAY_CONFIG_PATH}`,
        "info",
      );
    },
  });
}
