// P3 smoke test: bridge session-management commands.
// Usage: PIPILOT_TEST_URL='ws://127.0.0.1:9377?token=...' node test-sessions.mjs
import WebSocket from "ws";

const url = process.argv[2] ?? process.env.PIPILOT_TEST_URL;
if (!url) throw new Error("Pass a WebSocket URL or set PIPILOT_TEST_URL");

const ws = new WebSocket(url);
const pending = new Map();
let seq = 0;
const events = [];

ws.on("message", (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.type === "response" && msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  } else {
    events.push(msg.type);
  }
});

function request(type, extra = {}) {
  const id = `s${++seq}`;
  return new Promise((res, rej) => {
    pending.set(id, res);
    ws.send(JSON.stringify({ id, type, ...extra }));
    setTimeout(() => rej(new Error(`timeout: ${type}`)), 15000);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

ws.on("open", async () => {
  try {
    const dirs = await request("bridge_list_dirs");
    console.log("list_dirs success:", dirs.success, "dirs:", dirs.data.dirs.length);
    for (const d of dirs.data.dirs.slice(0, 5)) {
      console.log(`  ${d.sessionCount}\t${d.cwd}`);
    }

    const homeDir = dirs.data.dirs.find((d) => d.cwd === "/home/sisct");
    const sessions = await request("bridge_list_sessions", { cwd: "/home/sisct" });
    console.log("list_sessions success:", sessions.success,
      "count:", sessions.data.sessions.length,
      "expected:", homeDir?.sessionCount);
    const first = sessions.data.sessions[0];
    console.log("  newest:", first?.name ?? "(unnamed)", first?.timestamp, first?.id);

    const cfg = await request("bridge_get_config");
    console.log("get_config:", JSON.stringify(cfg.data));

    // Switch to the PiPilot project dir, then switch back.
    const target = "/home/sisct/Code/projects/FlutterProjects/PiPilot";
    const sw = await request("bridge_switch_dir", { cwd: target });
    console.log("switch_dir success:", sw.success, "->", sw.data?.cwd);
    await sleep(1200);
    const st = await request("get_state");
    console.log("get_state after switch:", st.success, "sessionFile:", st.data?.sessionFile);

    const back = await request("bridge_switch_dir", { cwd: cfg.data.piCwd });
    console.log("switch_back success:", back.success, "sessionId match:",
      back.data?.sessionId === cfg.data.sessionId);
    await sleep(1200);
    const st2 = await request("get_state");
    console.log("get_state after switch-back:", st2.success);

    console.log("events seen:", events.join(","));
    console.log("P3_OK");
  } catch (err) {
    console.error("P3_FAIL:", err.message);
    process.exitCode = 1;
  } finally {
    ws.close();
    process.exit();
  }
});
ws.on("error", (err) => {
  console.error("WS error:", err.message);
  process.exit(1);
});
