import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { gitBranchOf, sourceLabel } from "../src/git_branch.js";

/// 造一个临时目录当「仓库」:直接写 .git/HEAD,不依赖 git 命令。
function makeRepo(head: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-git-"));
  fs.mkdirSync(path.join(dir, ".git"));
  fs.writeFileSync(path.join(dir, ".git", "HEAD"), head);
  return dir;
}

test("普通仓库:读 .git/HEAD 拿到分支名", () => {
  const dir = makeRepo("ref: refs/heads/main\n");
  assert.equal(gitBranchOf(dir), "main");
});

test("分支名可以带斜线(feature/foo)", () => {
  const dir = makeRepo("ref: refs/heads/feature/foo\n");
  assert.equal(gitBranchOf(dir), "feature/foo");
});

test("子目录里开的 pi 也能上溯找到仓库分支", () => {
  const dir = makeRepo("ref: refs/heads/main\n");
  const nested = path.join(dir, "a", "b", "c");
  fs.mkdirSync(nested, { recursive: true });
  assert.equal(gitBranchOf(nested), "main");
});

test("worktree:.git 是 gitdir 文件,顺着它读真实 HEAD", () => {
  // 主仓库的 worktrees/<name>/HEAD 才是这个 worktree 的分支
  const mainRepo = makeRepo("ref: refs/heads/main\n");
  const wtGitdir = path.join(mainRepo, ".git", "worktrees", "wt1");
  fs.mkdirSync(wtGitdir, { recursive: true });
  fs.writeFileSync(path.join(wtGitdir, "HEAD"), "ref: refs/heads/topic\n");

  const worktree = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-wt-"));
  fs.writeFileSync(path.join(worktree, ".git"), `gitdir: ${wtGitdir}\n`);
  assert.equal(gitBranchOf(worktree), "topic");
});

test("不是 git 仓库:返回 null", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-plain-"));
  assert.equal(gitBranchOf(dir), null);
});

test("detached HEAD(裸 SHA):没有分支名,返回 null", () => {
  const dir = makeRepo("0123456789abcdef0123456789abcdef01234567\n");
  assert.equal(gitBranchOf(dir), null);
});

test("sourceLabel:git 仓库是「目录名 · 分支」", () => {
  const dir = makeRepo("ref: refs/heads/main\n");
  assert.equal(sourceLabel(dir), `${path.basename(dir)} · main`);
});

test("sourceLabel:非 git 仓库只有目录名,不挂尾巴", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pipilot-plain-"));
  assert.equal(sourceLabel(dir), path.basename(dir));
});
