import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import { gunzipSync } from "node:zlib";
import { decodeFrameV2, P2P_FRAME_V2_TYPE } from "../src/p2p_frame_v2.js";
import {
  encodeTransferV2,
  TransferRetainedStore,
  TransferV2Assembler,
  V2_GZIP_MIN_BYTES,
  V2_PAGE_BYTES,
} from "../src/p2p_transfer_v2.js";

function feedAll(
  assembler: TransferV2Assembler,
  frames: Buffer[],
): { message?: string; replies: Buffer[] } {
  let message: string | undefined;
  const replies: Buffer[] = [];
  for (const frame of frames) {
    const result = assembler.onFrame(frame);
    if (result.message !== undefined) message = result.message;
    replies.push(...result.replies);
  }
  return { message, replies };
}

test("v2 transfer: 小消息 identity 完整往返", () => {
  const text = JSON.stringify({ type: "hub_sync", data: "x".repeat(1000) });
  const transfer = encodeTransferV2(text);
  const assembler = new TransferV2Assembler();
  const { message, replies } = feedAll(assembler, transfer.frames);
  assert.equal(message, text);
  // DONE 全齐 → 回 ACK
  assert.equal(replies.length, 1);
  assert.equal(decodeFrameV2(replies[0]).type, P2P_FRAME_V2_TYPE.ack);
});

test("v2 transfer: 大消息 gzip 分页往返,线体积显著缩小", () => {
  // 1MB 高重复 JSON:压缩率应极高。
  const text = JSON.stringify({
    entries: Array.from({ length: 2000 }, (_, i) => ({
      role: "user",
      text: `hello world ${i % 10} `.repeat(20),
    })),
  });
  assert.ok(text.length > V2_GZIP_MIN_BYTES * 10);
  const transfer = encodeTransferV2(text);
  const wireBytes = transfer.frames.reduce((sum, f) => sum + f.length, 0);
  assert.ok(
    wireBytes < text.length / 5,
    `wire ${wireBytes} vs text ${text.length}`,
  );
  // BEGIN meta 声明 gzip
  const begin = decodeFrameV2(transfer.frames[0]);
  assert.equal(begin.type, P2P_FRAME_V2_TYPE.begin);
  assert.equal(begin.meta?.encoding, "gzip");
  const assembler = new TransferV2Assembler();
  const { message } = feedAll(assembler, transfer.frames);
  assert.equal(message, text);
});

/// 不可压缩文本(random hex):保证分页数不受 gzip 影响,测试确定性。
function incompressibleText(pages: number): string {
  return crypto.randomBytes(V2_PAGE_BYTES * pages).toString("hex");
}

test("v2 transfer: DONE 前丢页 → NACK,留存重发后完成", () => {
  const text = incompressibleText(3);
  const transfer = encodeTransferV2(text);
  const dataFrames = transfer.frames.filter(
    (frame) => decodeFrameV2(frame).type === P2P_FRAME_V2_TYPE.data,
  );
  assert.ok(dataFrames.length >= 3, `expect >=3 pages, got ${dataFrames.length}`);
  // 丢第 2 个 DATA 页
  const dropped = decodeFrameV2(dataFrames[1]).pageIndex;
  const framesWithout = transfer.frames.filter((frame) => {
    const decoded = decodeFrameV2(frame);
    return !(
      decoded.type === P2P_FRAME_V2_TYPE.data && decoded.pageIndex === dropped
    );
  });
  const assembler = new TransferV2Assembler();
  const { message: earlyMessage, replies } = feedAll(assembler, framesWithout);
  assert.equal(earlyMessage, undefined);
  assert.equal(replies.length, 1);
  const nack = decodeFrameV2(replies[0]);
  assert.equal(nack.type, P2P_FRAME_V2_TYPE.nack);
  assert.deepEqual(nack.meta?.missing, [dropped]);

  // 发送方留存应答 NACK
  const store = new TransferRetainedStore();
  store.add(transfer);
  const resends = store.resendFrames(
    transfer.transferId.toString("hex"),
    [dropped],
    false,
  );
  assert.ok(resends);
  // DATA 页 + 末尾补发的 DONE
  assert.equal(resends.length, 2);
  let message: string | undefined;
  for (const frame of resends) {
    const result = assembler.onFrame(frame);
    if (result.message) message = result.message;
  }
  assert.equal(message, text);
});

test("v2 transfer: 断线续传——pendingResumes + resume NACK + BEGIN 重建", () => {
  const text = incompressibleText(4);
  const transfer = encodeTransferV2(text);
  const begin = decodeFrameV2(transfer.frames[0]);
  const pageCount = begin.pageCount;
  assert.ok(pageCount >= 4);
  const assembler = new TransferV2Assembler();
  // 只收到 BEGIN + 第 0 页就断线
  assembler.onFrame(transfer.frames[0]);
  assembler.onFrame(transfer.frames[1]);
  const pending = assembler.pendingResumes();
  assert.equal(pending.length, 1);
  assert.deepEqual(
    pending[0].missing,
    Array.from({ length: pageCount - 1 }, (_, i) => i + 1),
  );

  // 重连后发 resume NACK
  const resumeNack = TransferV2Assembler.resumeNackFrame(
    pending[0].transferIdHex,
    pending[0].missing,
    pageCount,
  );
  const nackDecoded = decodeFrameV2(resumeNack);
  assert.equal(nackDecoded.meta?.resume, true);

  // 发送方留存:resume 需补 BEGIN + 缺失页
  const store = new TransferRetainedStore();
  store.add(transfer);
  const resends = store.resendFrames(
    pending[0].transferIdHex,
    pending[0].missing,
    true,
  );
  assert.ok(resends);
  // BEGIN + missing pages + 末尾补发的 DONE
  assert.equal(resends.length, 1 + (pageCount - 1) + 1);
  assert.equal(decodeFrameV2(resends[0]).type, P2P_FRAME_V2_TYPE.begin);
  // 接收方补完后由末尾的 DONE 触发交付
  let message: string | undefined;
  for (const frame of resends) {
    const result = assembler.onFrame(frame);
    if (result.message) message = result.message;
  }
  assert.equal(message, text);
});

test("v2 transfer: ACK 后留存释放;gzip 载荷可独立校验", () => {
  const text = JSON.stringify({ data: "z".repeat(100_000) });
  const transfer = encodeTransferV2(text);
  const store = new TransferRetainedStore();
  store.add(transfer);
  assert.notEqual(
    store.resendFrames(transfer.transferId.toString("hex"), [0], false),
    null,
  );
  store.ack(transfer.transferId.toString("hex"));
  assert.equal(
    store.resendFrames(transfer.transferId.toString("hex"), [0], false),
    null,
  );
  // BEGIN 声明 gzip 时 DATA 拼回后可 gunzip
  const begin = decodeFrameV2(transfer.frames[0]);
  if (begin.meta?.encoding === "gzip") {
    const joined = Buffer.concat(
      transfer.frames
        .slice(1, -1)
        .map((frame) => decodeFrameV2(frame).payload ?? Buffer.alloc(0)),
    );
    assert.equal(gunzipSync(joined).toString("utf8"), text);
  }
});

test("v2 transfer: ABORT 丢弃 assembly,坏帧不炸", () => {
  const text = incompressibleText(2);
  const transfer = encodeTransferV2(text);
  const assembler = new TransferV2Assembler();
  assembler.onFrame(transfer.frames[0]);
  assert.equal(assembler.pendingResumes().length, 1);
  // ABORT
  assembler.onFrame(
    transfer.frames[transfer.frames.length - 1].subarray(0, 30) as Buffer,
  );
  // 坏帧直接忽略
  assert.deepEqual(assembler.onFrame(Buffer.from([1, 2, 3])).replies, []);
});

import {
  encodeFrameV2,
} from "../src/p2p_frame_v2.js";
import {
  V2_MAX_PAGE_PAYLOAD_BYTES,
  V2_RETENTION_MS,
} from "../src/p2p_transfer_v2.js";
import { gzipSync } from "node:zlib";

test("v2 校验: 未知 encoding 直接 ABORT,不当成 identity 拼", () => {
  const assembler = new TransferV2Assembler();
  const transferId = crypto.randomBytes(16);
  const result = assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      meta: { encoding: "brotli-evil", size: 10 },
    }),
  );
  assert.equal(result.replies.length, 1, "必须回一帧");
  const reply = decodeFrameV2(result.replies[0]!);
  assert.equal(reply.type, P2P_FRAME_V2_TYPE.abort);
  assert.equal(reply.meta?.reason, "unsupported encoding");
});

test("v2 校验: 声明 size 越界直接 ABORT", () => {
  const assembler = new TransferV2Assembler();
  const transferId = crypto.randomBytes(16);
  const result = assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      meta: { encoding: "identity", size: 64 * 1024 * 1024 },
    }),
  );
  const reply = decodeFrameV2(result.replies[0]!);
  assert.equal(reply.type, P2P_FRAME_V2_TYPE.abort);
  assert.equal(reply.meta?.reason, "declared size out of range");
});

test("v2 校验: 超大单页直接 ABORT,不计入累计字节", () => {
  const assembler = new TransferV2Assembler();
  const transferId = crypto.randomBytes(16);
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount: 2,
      meta: { encoding: "identity", size: 1000 },
    }),
  );
  const before = assembler.assemblyBytes;
  const result = assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.data,
      transferId,
      pageIndex: 0,
      pageCount: 2,
      payload: Buffer.alloc(V2_MAX_PAGE_PAYLOAD_BYTES + 1, 0x41),
    }),
  );
  const reply = decodeFrameV2(result.replies[0]!);
  assert.equal(reply.type, P2P_FRAME_V2_TYPE.abort);
  assert.equal(reply.meta?.reason, "page too large");
  assert.equal(assembler.assemblyBytes, before, "越界页不得计入累计字节");
});

test("v2 校验: gzip bomb 不会交付,也不会吃爆内存", () => {
  const assembler = new TransferV2Assembler();
  const transferId = crypto.randomBytes(16);
  // 32MB 全零压缩后只有几十 KB —— 解压无上限时就是内存炸弹。
  const bomb = gzipSync(Buffer.alloc(32 * 1024 * 1024, 0));
  assert.ok(bomb.length < V2_MAX_PAGE_PAYLOAD_BYTES, "压缩体应当很小");
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      // 故意谎报一个合法范围内的 size,让 BEGIN 阶段过关。
      meta: { encoding: "gzip", size: 1024 },
    }),
  );
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.data,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      payload: bomb,
    }),
  );
  const done = assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.done,
      transferId,
      pageIndex: 0,
      pageCount: 1,
    }),
  );
  assert.equal(done.message, undefined, "gzip bomb 不得交付");
  assert.equal(done.replies.length, 0, "不得回 ACK");
});

test("v2 校验: size 不符不交付(分页错位/重复页)", () => {
  const assembler = new TransferV2Assembler();
  const transferId = crypto.randomBytes(16);
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      meta: { encoding: "identity", size: 999 },
    }),
  );
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.data,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      payload: Buffer.from("short"),
    }),
  );
  const done = assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.done,
      transferId,
      pageIndex: 0,
      pageCount: 1,
    }),
  );
  assert.equal(done.message, undefined, "声明 size 与实际不符必须拒绝交付");
});

test("v2 校验: sha256 不符不交付", () => {
  const assembler = new TransferV2Assembler();
  const transferId = crypto.randomBytes(16);
  const body = Buffer.from('{"type":"x"}', "utf8");
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.begin,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      meta: {
        encoding: "identity",
        size: body.length,
        sha256: "0".repeat(64), // 故意错的 hash
      },
    }),
  );
  assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.data,
      transferId,
      pageIndex: 0,
      pageCount: 1,
      payload: body,
    }),
  );
  const done = assembler.onFrame(
    encodeFrameV2({
      type: P2P_FRAME_V2_TYPE.done,
      transferId,
      pageIndex: 0,
      pageCount: 1,
    }),
  );
  assert.equal(done.message, undefined, "hash 不符必须拒绝交付");
});

test("v2 校验: 正常 transfer 带 sha256 仍能往返", () => {
  const text = JSON.stringify({ type: "hub_sync", data: "y".repeat(50_000) });
  const transfer = encodeTransferV2(text);
  const begin = decodeFrameV2(transfer.frames[0]!);
  assert.match(String(begin.meta?.sha256), /^[0-9a-f]{64}$/, "BEGIN 应带 sha256");
  const assembler = new TransferV2Assembler();
  const { message } = feedAll(assembler, transfer.frames);
  assert.equal(message, text, "带 hash 校验的正常路径必须仍然通");
});

test("v2 留存: 过期后 resendFrames 返回 null,不再刷新时间戳复活", () => {
  // 注入时钟:TTL 语义必须确定性可测。探针曾确认 60,001ms 后 resendFrames
  // 仍能取出并刷新 at —— 等于 TTL 永不生效,几十 MB 留存可无限期驻留。
  let now = 1_000_000;
  const store = new TransferRetainedStore(() => now);
  const transfer = encodeTransferV2(
    JSON.stringify({ type: "response", data: "z".repeat(100_000) }),
  );
  store.add(transfer);
  const key = transfer.transferId.toString("hex");
  assert.ok(store.resendFrames(key, [0], false), "刚存入应可重发");
  assert.ok(store.retainedBytes > 0);

  // 刚好没过期。
  now += V2_RETENTION_MS - 1;
  assert.ok(store.resendFrames(key, [0], false), "TTL 内必须仍可重发");

  // 越过 TTL:必须返回 null 并释放字节,而不是刷新 at 复活。
  now += V2_RETENTION_MS + 1;
  assert.equal(
    store.resendFrames(key, [0], false),
    null,
    "过期留存必须返回 null(修复前它会被取出并刷新 at)",
  );
  assert.equal(store.retainedBytes, 0, "过期必须释放字节预算");
});

test("v2 留存: 空闲期 sweepExpired 能主动回收(不依赖 add 触发)", () => {
  let now = 5_000_000;
  const store = new TransferRetainedStore(() => now);
  store.add(
    encodeTransferV2(JSON.stringify({ type: "response", data: "q".repeat(80_000) })),
  );
  assert.ok(store.retainedBytes > 0);

  now += V2_RETENTION_MS + 1;
  // 没有任何新 transfer 进来:修复前 sweep 只在 add 时跑,这些字节会一直驻留。
  store.sweepExpired();
  assert.equal(store.retainedBytes, 0, "主动回收必须释放过期留存");
});

test("v2 留存: ACK 立即释放", () => {
  const store = new TransferRetainedStore();
  const transfer = encodeTransferV2(
    JSON.stringify({ type: "response", data: "z".repeat(100_000) }),
  );
  store.add(transfer);
  const key = transfer.transferId.toString("hex");
  store.ack(key);
  assert.equal(store.resendFrames(key, [0], false), null);
  assert.equal(store.retainedBytes, 0);
});
