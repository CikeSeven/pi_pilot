import * as fs from "node:fs";
import * as path from "node:path";

/// 从 cwd 向上找 .git,读出当前分支名。
///
/// 不用 `git branch --show-current`:注册时同步 spawn 一个进程太慢,
/// 而且桌面环境未必总能跑 git。直接读文件就够:
/// - `.git` 是目录 → 读 `.git/HEAD`(普通仓库)
/// - `.git` 是文件 → 内容是 `gitdir: <路径>`,读 `<路径>/HEAD`(worktree/submodule)
/// - HEAD 是 `ref: refs/heads/<分支>` → 返回分支名
/// - HEAD 是裸 SHA(detached)→ 没有分支名,返回 null
///
/// 一路上溯到文件系统根,子目录里开的 pi 也能找到所属仓库的分支。
export function gitBranchOf(cwd: string): string | null {
  let dir = path.resolve(cwd);
  for (;;) {
    const dotGit = path.join(dir, ".git");
    let stat: fs.Stats;
    try {
      stat = fs.statSync(dotGit);
    } catch {
      // 这一层没有 .git,继续往上
      const parent = path.dirname(dir);
      if (parent === dir) return null;
      dir = parent;
      continue;
    }
    const headFile = stat.isDirectory()
      ? path.join(dotGit, "HEAD")
      : headFileFromGitfile(dotGit);
    if (!headFile) return null;
    return branchFromHead(headFile);
  }
}

/// 源标签:目录名 + git 分支;不是 git 仓库(或 detached HEAD)就只有目录名。
/// PID 曾经挂在目录名后面 —— 它只用于区分源,对人认读是噪音。
export function sourceLabel(cwd: string): string {
  const base = path.basename(cwd) || cwd;
  const branch = gitBranchOf(cwd);
  return branch ? `${base} · ${branch}` : base;
}

/// `.git` 是文件时(worktree / submodule),内容是 `gitdir: <真实 git 目录>`。
function headFileFromGitfile(gitfile: string): string | null {
  let text: string;
  try {
    text = fs.readFileSync(gitfile, "utf8");
  } catch {
    return null;
  }
  const match = /^gitdir:\s*(.+)$/m.exec(text.trim());
  if (!match) return null;
  const gitdir = match[1]!.trim();
  // gitdir 可以是相对路径 —— 相对的是 .git 文件所在目录
  const resolved = path.isAbsolute(gitdir)
    ? gitdir
    : path.resolve(path.dirname(gitfile), gitdir);
  return path.join(resolved, "HEAD");
}

/// 读 HEAD:`ref: refs/heads/main` → `main`;裸 SHA(detached)→ null。
function branchFromHead(headFile: string): string | null {
  let text: string;
  try {
    text = fs.readFileSync(headFile, "utf8").trim();
  } catch {
    return null;
  }
  const match = /^ref:\s*refs\/heads\/(.+)$/.exec(text);
  if (!match) return null;
  const branch = match[1]!.trim();
  return branch.length > 0 ? branch : null;
}
