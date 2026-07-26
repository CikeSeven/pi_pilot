import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { loadRelayConfig, RELAY_CONFIG_PATH } from "./config.js";
import { DesktopRelay } from "./relay.js";

export default function pipilotDesktopRelay(pi: ExtensionAPI): void {
  let relay: DesktopRelay | undefined;

  pi.on("session_start", (_event, ctx) => {
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
    relay = new DesktopRelay(pi, config);
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

  pi.on("agent_start", boundary);
  pi.on("agent_end", boundary);
  pi.on("agent_settled", emitAndSnapshot);
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
  pi.on("session_compact", emitAndSnapshot);
  pi.on("input", emit);
  pi.on("user_bash", emit);

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
