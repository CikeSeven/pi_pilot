import assert from "node:assert/strict";
import test from "node:test";
import { cloneForWire, encodeForWire } from "../src/serialization.js";

test("wire cloning breaks shallow references", () => {
  const source = { nested: { text: "before" }, list: [{ value: 1 }] };
  const cloned = cloneForWire(source);
  source.nested.text = "after";
  source.list[0]!.value = 2;
  assert.equal(cloned.nested.text, "before");
  assert.equal(cloned.list[0]!.value, 1);
});

test("wire encoding normalizes bigint and Error", () => {
  const encoded = encodeForWire({ count: 42n, error: new Error("boom") });
  const parsed = JSON.parse(encoded);
  assert.equal(parsed.count, "42");
  assert.equal(parsed.error.message, "boom");
});

test("wire encoding enforces a byte ceiling", () => {
  assert.throws(() => encodeForWire({ text: "x".repeat(50) }, 10), /exceeds/);
});
