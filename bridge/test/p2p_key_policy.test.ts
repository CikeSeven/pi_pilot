import assert from "node:assert/strict";
import test from "node:test";
import { WebSocketServer } from "ws";
import { P2pHost } from "../src/p2p_host.js";
import {
  isValidP2pDeviceId,
  isValidP2pPairingKey,
} from "../src/p2p_key_policy.js";

const VALID_PAIRING_KEY = "S3cret-Key-2026!";

test("P2P device names enforce character and length boundaries", () => {
  assert.equal(isValidP2pDeviceId("ab"), false);
  assert.equal(isValidP2pDeviceId("abc"), true);
  assert.equal(isValidP2pDeviceId("a".repeat(64)), true);
  assert.equal(isValidP2pDeviceId("a".repeat(65)), false);
  assert.equal(isValidP2pDeviceId("Az09._-"), true);

  for (const value of [
    "bad name",
    "bad/name",
    "bad\\name",
    "bad\nname",
    "设备名",
  ]) {
    assert.equal(isValidP2pDeviceId(value), false, value);
  }
});

test("P2P pairing keys enforce length, ASCII, and character classes", () => {
  assert.equal(isValidP2pPairingKey(`${"a".repeat(12)}A1!`), false);
  assert.equal(isValidP2pPairingKey(`${"a".repeat(13)}A1!`), true);
  assert.equal(isValidP2pPairingKey(`${"a".repeat(125)}A1!`), true);
  assert.equal(isValidP2pPairingKey(`${"a".repeat(126)}A1!`), false);
  assert.equal(isValidP2pPairingKey(`Aa1${"!".repeat(12)}~`), true);
  assert.equal(isValidP2pPairingKey("A1".repeat(8)), false);

  for (const value of [
    "Aa1! with spaces",
    `Aa1!${"x".repeat(12)}\x7f`,
    `Aa1!${"x".repeat(12)}\n`,
    `Aa1!${"x".repeat(12)}中`,
  ]) {
    assert.equal(isValidP2pPairingKey(value), false, value);
  }
});

test("P2pHost rejects invalid local pairing config before opening a socket", async () => {
  const wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
  if (!wss.address()) {
    await new Promise<void>((resolve) => wss.once("listening", resolve));
  }
  const address = wss.address();
  assert.ok(address && typeof address === "object");

  let connections = 0;
  wss.on("connection", (socket) => {
    connections++;
    socket.terminate();
  });
  const logs: string[] = [];
  const createHost = (deviceId: string, secret: string) =>
    new P2pHost({
      rendezvousUrl: `ws://127.0.0.1:${address.port}`,
      deviceId,
      secret,
      validateMobileToken: () => true,
      acceptMobile: () => {},
      log: (line) => logs.push(line),
    });

  const invalidDevice = createHost("bad/device", VALID_PAIRING_KEY);
  const invalidKey = createHost("valid-device", "short-secret");
  assert.equal(invalidDevice.start(), false);
  assert.equal(invalidKey.start(), false);
  await new Promise((resolve) => setTimeout(resolve, 50));

  assert.equal(connections, 0);
  assert.ok(logs.some((line) => line.includes("设备名")));
  assert.ok(logs.some((line) => line.includes("配对 Key")));
  assert.equal(
    logs.some((line) => line.includes("short-secret")),
    false,
  );

  invalidDevice.stop();
  invalidKey.stop();
  await new Promise<void>((resolve, reject) => {
    wss.close((error) => (error ? reject(error) : resolve()));
  });
});
