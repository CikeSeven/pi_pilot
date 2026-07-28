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
}

export interface CommandRuntime {
  pi: Pick<
    ExtensionAPI,
    "sendUserMessage" | "setModel" | "getThinkingLevel" | "setThinkingLevel" | "setSessionName"
  >;
  ctx: Pick<ExtensionContext, "abort" | "isIdle" | "modelRegistry">;
  /// 会话回退:relay 用缓存的命令上下文执行(普通 ExtensionContext 上没有 navigateTree)。
  navigate?: (entryId: string | undefined) => Promise<unknown>;
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
      if (runtime.ctx.isIdle()) {
        runtime.pi.sendUserMessage(command.message);
        return { accepted: true, delivery: "immediate" };
      }
      if (command.streamingBehavior !== "steer" && command.streamingBehavior !== "followUp") {
        throw new Error("busy desktop source requires steer or followUp delivery");
      }
      runtime.pi.sendUserMessage(command.message, { deliverAs: command.streamingBehavior });
      return { accepted: true, delivery: command.streamingBehavior };
    }

    case "abort":
      runtime.ctx.abort();
      return { aborted: true };

    case "compact":
      // pi 没有把 compact 暴露到 ExtensionAPI 上,只能走用户消息通道的斜杠命令。
      throw new Error("compact is not available on the desktop relay");

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
