import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { loadRelayConfig, RELAY_CONFIG_PATH } from "./config.js";
import { NavCommandContextCache, registerNavCommands } from "./nav_commands.js";
import { DesktopRelay } from "./relay.js";

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
    relay?.emitBoundary(event, ctx);
  });
  pi.on("agent_settled", (event, ctx) => {
    relay?.setStreaming(false, ctx);
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
  pi.on("session_tree", emitAndSnapshot);
  pi.on("session_before_compact", (event, ctx) => {
    relay?.setCompacting(true, ctx);
    relay?.emitBoundary(event, ctx);
    relay?.snapshot(ctx);
  });
  pi.on("session_compact", (event, ctx) => {
    relay?.setCompacting(false, ctx);
    relay?.emitBoundary(event, ctx);
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

  registerNavCommands(pi, navCache, (result, ctx) => {
    relay?.emitNavResult(result, ctx);
  });

  pi.registerCommand("pipilot", {
    description: "Show PiPilot desktop relay status",
    handler: async (_args, ctx) => {
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
