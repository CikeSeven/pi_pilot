import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * Reads pi's on-disk session store (~/.pi/agent/sessions/<encoded-cwd>/*.jsonl).
 *
 * The directory-name encoding is lossy (path separators and real hyphens both
 * become "-"), so we never decode it: the authoritative cwd/id/name are read
 * from the first two lines of each session file instead.
 *
 *   line 1: {"type":"session","id":...,"timestamp":...,"cwd":...}
 *   line 2: {"type":"session_info",...,"name":...}   (only when named)
 */

export const SESSIONS_ROOT = path.join(os.homedir(), ".pi", "agent", "sessions");

export interface DirInfo {
  cwd: string;
  sessionCount: number;
  lastActive: string | null;
}

export interface SessionInfo {
  path: string;
  id: string;
  name: string | null;
  timestamp: string;
  sizeBytes: number;
}

interface HeadMeta {
  id?: string;
  cwd?: string;
  timestamp?: string;
  name?: string;
}

function readHeadLines(filePath: string, maxLines: number): string[] {
  const fd = fs.openSync(filePath, "r");
  try {
    const buf = Buffer.alloc(8192);
    const bytes = fs.readSync(fd, buf, 0, buf.length, 0);
    return buf.toString("utf8", 0, bytes).split("\n").filter(Boolean).slice(0, maxLines);
  } finally {
    fs.closeSync(fd);
  }
}

function parseHead(filePath: string): HeadMeta | null {
  try {
    const [first, second] = readHeadLines(filePath, 2);
    const meta: HeadMeta = {};
    if (first) {
      const j = JSON.parse(first);
      if (j.type === "session") {
        meta.id = j.id;
        meta.cwd = j.cwd;
        meta.timestamp = j.timestamp;
      }
    }
    if (second) {
      const j = JSON.parse(second);
      if (j.type === "session_info" && typeof j.name === "string") meta.name = j.name;
    }
    return meta;
  } catch {
    return null;
  }
}

interface SessionFile {
  path: string;
  mtimeMs: number;
  sizeBytes: number;
}

/** .jsonl files in a dir, most-recently-modified first. */
function sessionFiles(dirPath: string): SessionFile[] {
  let names: string[];
  try {
    names = fs.readdirSync(dirPath);
  } catch {
    return [];
  }
  const out: SessionFile[] = [];
  for (const name of names) {
    if (!name.endsWith(".jsonl")) continue;
    const p = path.join(dirPath, name);
    try {
      const st = fs.statSync(p);
      out.push({ path: p, mtimeMs: st.mtimeMs, sizeBytes: st.size });
    } catch {
      // vanished between readdir/stat — skip
    }
  }
  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return out;
}

function storageDirs(): string[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(SESSIONS_ROOT, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries.filter((e) => e.isDirectory()).map((e) => path.join(SESSIONS_ROOT, e.name));
}

/** All working directories that have at least one session, most recent first. */
export function listDirs(): DirInfo[] {
  const dirs: DirInfo[] = [];
  for (const dirPath of storageDirs()) {
    const files = sessionFiles(dirPath);
    if (files.length === 0) continue;
    const meta = parseHead(files[0]!.path);
    if (!meta?.cwd) continue;
    dirs.push({ cwd: meta.cwd, sessionCount: files.length, lastActive: meta.timestamp ?? null });
  }
  dirs.sort((a, b) => (b.lastActive ?? "").localeCompare(a.lastActive ?? ""));
  return dirs;
}

/** Sessions belonging to one working directory, most recent first. */
export function listSessions(cwd: string): SessionInfo[] {
  for (const dirPath of storageDirs()) {
    const files = sessionFiles(dirPath);
    if (files.length === 0) continue;
    if (parseHead(files[0]!.path)?.cwd !== cwd) continue;
    return files.map((f) => {
      const meta = parseHead(f.path) ?? {};
      return {
        path: f.path,
        id: meta.id ?? path.basename(f.path, ".jsonl"),
        name: meta.name ?? null,
        timestamp: meta.timestamp ?? new Date(f.mtimeMs).toISOString(),
        sizeBytes: f.sizeBytes,
      };
    });
  }
  return [];
}
