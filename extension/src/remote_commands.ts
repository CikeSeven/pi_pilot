import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const SAFE_REMOTE_COMMANDS = [
  "prompt",
  "abort",
  "set_model",
  "set_thinking_level",
] as const;

const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);

export interface RemoteCommand {
  type?: unknown;
  message?: unknown;
  streamingBehavior?: unknown;
  provider?: unknown;
  modelId?: unknown;
  level?: unknown;
}

export interface CommandRuntime {
  pi: Pick<ExtensionAPI, "sendUserMessage" | "setModel" | "getThinkingLevel" | "setThinkingLevel">;
  ctx: Pick<ExtensionContext, "abort" | "isIdle" | "modelRegistry">;
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

    default:
      throw new Error(`unsupported desktop command: ${String(command.type)}`);
  }
}
