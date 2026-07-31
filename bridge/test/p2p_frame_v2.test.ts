import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import {
  decodeFrameV2,
  encodeFrameV2,
  P2P_FRAME_V2_TYPE,
  transferIdFromUuid,
  transferIdToUuid,
} from "../src/p2p_frame_v2.js";

interface Vector {
  name: string;
  frame: {
    type: number;
    transferIdUuid: string;
    pageIndex: number;
    pageCount: number;
    meta: Record<string, unknown> | null;
    payloadHex: string;
  };
  hex: string;
}

const vectors = JSON.parse(
  fs.readFileSync(
    new URL("../../protocol/p2p_frame_v2_vectors.json", import.meta.url),
    "utf8",
  ),
).vectors as Vector[];

test("chunk-v2 帧:跨端测试向量 encode/decode 逐字节一致", () => {
  for (const vector of vectors) {
    const frame = {
      type: vector.frame.type,
      transferId: transferIdFromUuid(vector.frame.transferIdUuid),
      pageIndex: vector.frame.pageIndex,
      pageCount: vector.frame.pageCount,
      meta: vector.frame.meta ?? undefined,
      payload: vector.frame.payloadHex
        ? Buffer.from(vector.frame.payloadHex, "hex")
        : undefined,
    };
    assert.equal(
      encodeFrameV2(frame).toString("hex"),
      vector.hex,
      `${vector.name}: encode hex mismatch`,
    );
    const decoded = decodeFrameV2(Buffer.from(vector.hex, "hex"));
    assert.equal(decoded.type, vector.frame.type, vector.name);
    assert.equal(
      transferIdToUuid(decoded.transferId),
      vector.frame.transferIdUuid,
      vector.name,
    );
    assert.equal(decoded.pageIndex, vector.frame.pageIndex, vector.name);
    assert.equal(decoded.pageCount, vector.frame.pageCount, vector.name);
    assert.deepEqual(decoded.meta ?? null, vector.frame.meta, vector.name);
    assert.equal(
      decoded.payload?.toString("hex") ?? "",
      vector.frame.payloadHex,
      vector.name,
    );
  }
});

test("chunk-v2 帧:坏魔数/短帧/坏 headerExtLen 一律 FormatException", () => {
  assert.throws(() => decodeFrameV2(Buffer.alloc(10)), /too short/);
  const badMagic = Buffer.alloc(30);
  badMagic[0] = 0x50;
  badMagic[1] = 0x41;
  assert.throws(() => decodeFrameV2(badMagic), /bad magic/);
  const good = encodeFrameV2({
    type: P2P_FRAME_V2_TYPE.done,
    transferId: Buffer.alloc(16),
  });
  const badExt = Buffer.from(good);
  badExt.writeUInt16BE(9999, 28);
  assert.throws(() => decodeFrameV2(badExt), /headerExtLen/);
});

test("chunk-v2 帧:UUID 十六进制往返", () => {
  const uuid = "3f786850-e387-4b2f-9d4a-1c6f2a9e0b51";
  assert.equal(transferIdToUuid(transferIdFromUuid(uuid)), uuid);
});
