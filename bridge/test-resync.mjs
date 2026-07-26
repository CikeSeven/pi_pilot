// Reconnect / incremental-sync smoke test.
// 1. Connect, fetch full entries, record leafId.
// 2. Disconnect. 3. Reconnect with `since: leafId` -> expect an empty diff.
// Usage: PIPILOT_TEST_URL='ws://127.0.0.1:9377?token=...' node test-resync.mjs
import WebSocket from "ws";

const url = process.argv[2] ?? process.env.PIPILOT_TEST_URL;
if (!url) throw new Error("Pass a WebSocket URL or set PIPILOT_TEST_URL");

function open(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const pending = new Map();
    let seq = 0;
    ws.on("open", () => {
      resolve({
        request(type, extra = {}) {
          const id = `t${++seq}`;
          return new Promise((res) => {
            pending.set(id, res);
            ws.send(JSON.stringify({ id, type, ...extra }));
          });
        },
        close: () => ws.close(),
      });
    });
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.type === "response" && msg.id && pending.has(msg.id)) {
        pending.get(msg.id)(msg);
        pending.delete(msg.id);
      }
    });
    ws.on("error", reject);
  });
}

const first = await open(url);
const full = await first.request("get_entries");
const leafId = full.data?.leafId;
console.log("initial entries:", full.data?.entries?.length, "leafId:", leafId);
first.close();

await new Promise((r) => setTimeout(r, 500));

const second = await open(url);
const diff = await second.request("get_entries", { since: leafId });
console.log("incremental success:", diff.success, "new entries:", diff.data?.entries?.length);
console.log(diff.success && diff.data.entries.length === 0 ? "RESYNC_OK" : "RESYNC_UNEXPECTED");
second.close();
process.exit(0);
