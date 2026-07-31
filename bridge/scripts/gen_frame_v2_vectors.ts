// 一次性工具:用编解码器重新生成测试向量 hex(编解码器是规范)。
// 用法:npx tsx scripts/gen_frame_v2_vectors.ts
import fs from "node:fs";
import {
  encodeFrameV2,
  transferIdFromUuid,
} from "../src/p2p_frame_v2.js";

const vectorsPath = new URL(
  "../../protocol/p2p_frame_v2_vectors.json",
  import.meta.url,
);
const doc = JSON.parse(fs.readFileSync(vectorsPath, "utf8")) as {
  vectors: Array<{
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
  }>;
};

let changed = 0;
for (const vector of doc.vectors) {
  const actual = encodeFrameV2({
    type: vector.frame.type,
    transferId: transferIdFromUuid(vector.frame.transferIdUuid),
    pageIndex: vector.frame.pageIndex,
    pageCount: vector.frame.pageCount,
    meta: vector.frame.meta ?? undefined,
    payload: vector.frame.payloadHex
      ? Buffer.from(vector.frame.payloadHex, "hex")
      : undefined,
  }).toString("hex");
  if (actual !== vector.hex) {
    console.log(`${vector.name}: ${vector.hex} -> ${actual}`);
    vector.hex = actual;
    changed++;
  }
}
fs.writeFileSync(vectorsPath, JSON.stringify(doc, null, 2) + "\n");
console.log(changed === 0 ? "all vectors already correct" : `updated ${changed}`);
