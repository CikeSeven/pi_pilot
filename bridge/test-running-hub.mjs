// Safe smoke test for an already-running Source Hub. It never sends a pi mutation.
// Usage: PIPILOT_TEST_URL='ws://127.0.0.1:9377?token=...' node test-running-hub.mjs
import WebSocket from "ws";

const url = process.argv[2] ?? process.env.PIPILOT_TEST_URL;
if (!url) throw new Error("Pass a WebSocket URL or set PIPILOT_TEST_URL");
const ws = new WebSocket(url);
const pending = new Map();
let seq = 0;
let hello;

ws.on("message", (data) => {
  const message = JSON.parse(data.toString());
  if (message.type === "bridge_hello") hello = message;
  if (message.type === "response" && typeof message.id === "string") {
    pending.get(message.id)?.(message);
    pending.delete(message.id);
  }
});

function request(type, extra = {}) {
  const id = `safe-${++seq}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout: ${type}`)), 5000);
    pending.set(id, (response) => {
      clearTimeout(timer);
      resolve(response);
    });
    ws.send(JSON.stringify({ type, id, ...extra }));
  });
}

await new Promise((resolve, reject) => {
  ws.once("open", resolve);
  ws.once("error", reject);
});
await new Promise((resolve) => setTimeout(resolve, 50));
if (hello?.version !== 2) throw new Error(`unexpected hello: ${JSON.stringify(hello)}`);

const listed = await request("hub_list_sources");
const source = listed.data?.sources?.find((item) => item.connected);
if (!source) throw new Error("no connected source");
const selected = await request("hub_select_source", { sourceId: source.id });
const state = await request("get_state");
const sync = await request("hub_sync");
const denied = await request("prompt", { message: "THIS MUST NOT BE DELIVERED" });
if (denied.success !== false) throw new Error("mutation unexpectedly accepted without lease");
const acquired = await request("hub_acquire_owner", { ttlMs: 5000 });
if (acquired.success !== true) throw new Error(`lease failed: ${acquired.error}`);
const released = await request("hub_release_owner", {
  leaseId: acquired.data.leaseId,
  fence: acquired.data.fence,
});
if (released.success !== true) throw new Error(`release failed: ${released.error}`);

console.log(
  JSON.stringify(
    {
      result: "RUNNING_HUB_OK",
      hubId: hello.hubId,
      source: { id: source.id, kind: source.kind, label: source.label },
      selected: selected.success,
      state: {
        sessionId: state.data?.sessionId,
        isStreaming: state.data?.isStreaming,
      },
      sync: { mode: sync.data?.mode, baseSeq: sync.data?.baseSeq },
      mutationDeniedWithoutLease: denied.success === false,
      leaseReleased: released.success,
    },
    null,
    2,
  ),
);
ws.close();
