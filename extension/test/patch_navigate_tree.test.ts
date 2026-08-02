/**
 * index.ts 的 ExtensionRunner 补丁:普通事件 ctx 也要能 navigateTree。
 *
 * 背景:pi 只把 navigateTree 挂在命令上下文上,但实现 handler 在会话建立
 * 时就绑到 runner 上且整个会话不解绑。补丁复刻 createCommandContext 的
 * 接法,让手机发起的远程回退不再要求用户先在电脑端跑一次 /pipilot。
 */
import assert from "node:assert/strict";
import test from "node:test";
import { ExtensionRunner } from "@earendil-works/pi-coding-agent";
import "../src/index.js";

type RunnerLike = {
  bindCommandContext: (actions: Record<string, unknown>) => void;
  createContext: () => Record<string, unknown>;
};

function fakeRunner(): RunnerLike {
  // 构造参数:createContext 只用得到延迟 getter,空壳就够。
  return new ExtensionRunner(
    [],
    {} as never,
    "/tmp",
    undefined as never,
    undefined as never,
  ) as unknown as RunnerLike;
}

function commandActions(calls: string[]): Record<string, unknown> {
  return {
    waitForIdle: async () => {},
    newSession: async () => ({ cancelled: false }),
    fork: async () => ({ cancelled: false }),
    navigateTree: async (targetId: string) => {
      calls.push(`navigateTree:${targetId}`);
      return { cancelled: false };
    },
    switchSession: async () => ({ cancelled: false }),
    reload: async () => {},
  };
}

test("补丁后普通事件 ctx 自带 navigateTree 并委托到会话级 handler", async () => {
  const runner = fakeRunner();
  const calls: string[] = [];
  runner.bindCommandContext(commandActions(calls));

  const ctx = runner.createContext();
  assert.equal(typeof ctx.navigateTree, "function");
  await (ctx.navigateTree as (id: string) => Promise<unknown>)("entry-1");
  assert.deepEqual(calls, ["navigateTree:entry-1"]);
});

test("补丁不覆盖 createCommandContext 已接好的 navigateTree", async () => {
  const runner = fakeRunner();
  const calls: string[] = [];
  runner.bindCommandContext(commandActions(calls));

  // createCommandContext 自己接 navigateTree;补丁必须只在缺失时补,
  // 不能改写 pi 原生命令上下文的行为。
  const cmdCtx = (
    runner as unknown as { createCommandContext: () => Record<string, unknown> }
  ).createCommandContext();
  assert.equal(typeof cmdCtx.navigateTree, "function");
  await (cmdCtx.navigateTree as (id: string) => Promise<unknown>)("entry-2");
  assert.deepEqual(calls, ["navigateTree:entry-2"]);
});
