#!/usr/bin/env node
// 测试用假 pi:讲最小 JSONL RPC。
// - 任意带 id 的请求 → 返回成功 response(get_state 带最小状态)
// - extension_ui_response(无 id 回执)→ 发出 extension_ui_echo 事件供测试断言
import process from "node:process";

let buffer = "";

function send(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

process.stdin.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  for (;;) {
    const idx = buffer.indexOf("\n");
    if (idx === -1) return;
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.type === "extension_ui_response") {
      send({
        type: "extension_ui_echo",
        receivedId: msg.id,
        value: msg.value ?? null,
        confirmed: msg.confirmed ?? null,
        cancelled: msg.cancelled ?? null,
      });
      continue;
    }
    if (typeof msg.id === "string") {
      const data =
        msg.type === "get_state"
          ? {
              sessionId: "fake-session",
              sessionName: "Fake",
              cwd: process.cwd(),
              isStreaming: false,
            }
          : { ok: true, command: msg.type };
      send({ type: "response", command: msg.type, id: msg.id, success: true, data });
    }
  }
});

process.stdin.on("end", () => process.exit(0));
