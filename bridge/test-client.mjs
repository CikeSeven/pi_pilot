// Manual smoke-test client for the PiPilot bridge.
// Usage: PIPILOT_TEST_URL='ws://127.0.0.1:9377?token=...' node test-client.mjs
import WebSocket from "ws";

const url = process.argv[2] ?? process.env.PIPILOT_TEST_URL;
if (!url) throw new Error("Pass a WebSocket URL or set PIPILOT_TEST_URL");
const ws = new WebSocket(url);

ws.on("open", () => {
  console.log(">> connected");
  ws.send(JSON.stringify({ id: "s1", type: "get_state" }));
  setTimeout(() => {
    console.log(">> sending prompt");
    ws.send(JSON.stringify({ id: "p1", type: "prompt", message: "Reply with exactly: PONG" }));
  }, 500);
  setTimeout(() => {
    ws.send(JSON.stringify({ id: "e1", type: "get_entries" }));
  }, 15000);
  setTimeout(() => process.exit(0), 20000);
});

ws.on("message", (data) => {
  const text = data.toString();
  console.log("<<", text.length > 600 ? text.slice(0, 600) + "…" : text);
});

ws.on("close", (code, reason) => {
  console.log(">> closed", code, reason.toString());
  process.exit(1);
});

ws.on("error", (err) => {
  console.error(">> error", err.message);
  process.exit(1);
});
