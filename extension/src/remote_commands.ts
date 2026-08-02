import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const SAFE_REMOTE_COMMANDS = [
  "prompt",
  "abort",
  "set_model",
  "set_thinking_level",
  "set_session_name",
  // 压缩上下文与会话内回退都是"会话内"操作,不会把电脑上正在用的会话抽走。
  // fork / new_session / switch_session 永远不在这个表里 —— 那会换掉人正在用的会话。
  "compact",
  "navigate_tree",
] as const;

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);

export interface RemoteCommand {
  type?: unknown;
  entryId?: unknown;
  message?: unknown;
  streamingBehavior?: unknown;
  provider?: unknown;
  modelId?: unknown;
  level?: unknown;
  name?: unknown;
  instructions?: unknown;
}

export interface InterruptibleContext {
  abort(): void;
  isIdle(): boolean;
  abortCompaction?: () => void;
  isCompacting?: () => boolean;
}

/** 中断生成或压缩,并等宿主真正退出忙碌态后再允许下一条命令。 */
export async function abortRemoteOperation(
  ctx: InterruptibleContext,
  options: { expectCompacting?: boolean; timeoutMs?: number } = {},
): Promise<{ compaction: boolean }> {
  const compacting = ctx.isCompacting?.() === true || options.expectCompacting === true;
  if (compacting && typeof ctx.abortCompaction !== "function") {
    throw new Error("desktop runtime cannot abort compaction");
  }

  // 两个控制器彼此独立:普通 abort 停 agent/retry,abortCompaction 停摘要模型。
  ctx.abort();
  ctx.abortCompaction?.();

  const deadline = Date.now() + (options.timeoutMs ?? 25_000);
  while (!ctx.isIdle() || ctx.isCompacting?.() === true) {
    if (Date.now() >= deadline) throw new Error("desktop did not stop in time");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return { compaction: compacting };
}

export interface CommandRuntime {
  pi: Pick<
    ExtensionAPI,
    "sendUserMessage" | "setModel" | "getThinkingLevel" | "setThinkingLevel" | "setSessionName"
  >;
  ctx: Pick<ExtensionContext, "abort" | "isIdle" | "modelRegistry" | "compact"> &
    Partial<Pick<InterruptibleContext, "abortCompaction" | "isCompacting">>;
  /// 中断必须等待宿主退出忙碌态;relay 在这里补压缩状态事件的收口。
  abortCurrent?: () => Promise<unknown>;
  /// 会话回退:relay 用缓存的命令上下文执行(普通 ExtensionContext 上没有 navigateTree)。
  navigate?: (entryId: string | undefined) => Promise<unknown>;
  /// 压缩出错时告知手机。ctx.compact() 不 await,错误只会走 onError 回调,
  /// 不接的话手机会永远停在「正在压缩」。
  onCompactError?: (message: string) => void;
}

export async function executeRemoteCommand(
  command: RemoteCommand,
  runtime: CommandRuntime,
): Promise<unknown> {
  switch (command.type) {
    case "prompt": {
      if (typeof command.message !== "string" || command.message.length === 0) {
        throw new Error("prompt message must be a non-empty string");
      }
      if (command.message.length > 100_000) throw new Error("prompt message is too large");
      if (runtime.ctx.isCompacting?.() === true) {
        throw new Error("desktop is compacting; abort first");
      }
      if (runtime.ctx.isIdle()) {
        runtime.pi.sendUserMessage(command.message);
        return { accepted: true, delivery: "immediate" };
      }
      // 普通忙碌(生成/retry)但客户端没指定投递方式时兜底排队。
      // 压缩已在上面单独拒绝:pi 0.82.1 没有压缩消息队列,不能把
      // followUp 当成「压缩后发送」。
      const delivery =
        command.streamingBehavior === "steer" || command.streamingBehavior === "followUp"
          ? command.streamingBehavior
          : "followUp";
      runtime.pi.sendUserMessage(command.message, { deliverAs: delivery });
      return { accepted: true, delivery };
    }

    case "abort":
      return runtime.abortCurrent
        ? await runtime.abortCurrent()
        : await abortRemoteOperation(runtime.ctx);

    case "compact": {
      // pi 确实把 compact 挂在 ExtensionContext 上(types.d.ts:240),
      // 以前这里直接抛错是误判。
      //
      // 它的声明就是「Trigger compaction without awaiting completion」—— 返回 void,
      // 所以这里只能报「已受理」。进展靠 session_before_compact /
      // session_compact 两个钩子事件流向手机,App 已经在听了。
      if (!runtime.ctx.isIdle()) {
        // 正在跑的一回合里发起压缩,pi 自己也不允许;报清楚总比默默失败好。
        throw new Error("desktop is busy; compact after this turn finishes");
      }
      const instructions =
        typeof command.instructions === "string" && command.instructions.trim().length > 0
          ? command.instructions.trim()
          : undefined;
      if (instructions && instructions.length > 10_000) {
        throw new Error("compact instructions are too large");
      }
      runtime.ctx.compact({
        ...(instructions ? { customInstructions: instructions } : {}),
        onError: (error) =>
          runtime.onCompactError?.(error instanceof Error ? error.message : String(error)),
      });
      return { accepted: true, ...(instructions ? { instructions } : {}) };
    }

    case "navigate_tree": {
      if (!runtime.navigate) {
        throw new Error("session rollback is unavailable in this desktop runtime");
      }
      const entryId =
        typeof command.entryId === "string" && command.entryId.length > 0
          ? command.entryId
          : undefined;
      return runtime.navigate(entryId);
    }

    case "set_model": {
      if (typeof command.provider !== "string" || typeof command.modelId !== "string") {
        throw new Error("provider and modelId are required");
      }
      const model = runtime.ctx.modelRegistry.find(command.provider, command.modelId);
      if (!model) throw new Error("model is not available in this desktop runtime");
      const changed = await runtime.pi.setModel(model);
      if (!changed) throw new Error("model credentials are unavailable");
      return model;
    }

    case "set_thinking_level": {
      if (typeof command.level !== "string" || !THINKING_LEVELS.has(command.level)) {
        throw new Error("invalid thinking level");
      }
      runtime.pi.setThinkingLevel(
        command.level as Parameters<ExtensionAPI["setThinkingLevel"]>[0],
      );
      return { level: runtime.pi.getThinkingLevel() };
    }

    case "set_session_name": {
      if (typeof command.name !== "string" || command.name.trim().length === 0) {
        throw new Error("session name must be a non-empty string");
      }
      if (command.name.length > 256) throw new Error("session name is too long");
      runtime.pi.setSessionName(command.name.trim());
      return { name: command.name.trim() };
    }

    default:
      throw new Error(`unsupported desktop command: ${String(command.type)}`);
  }
}
