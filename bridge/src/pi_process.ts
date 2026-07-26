import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

/**
 * Owns the `pi --mode rpc` child process.
 *
 * Pi speaks strict JSONL: records are delimited by LF only. We split on "\n"
 * ourselves (never readline, which also splits on U+2028/U+2029) and strip a
 * trailing "\r" so CRLF input is tolerated.
 */
export class PiProcess {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private buffer = "";
  stderrTail = "";

  onLine: (line: string) => void = () => {};
  onExit: (code: number | null, signal: NodeJS.Signals | null) => void = () => {};
  onSpawn: () => void = () => {};

  private restarting = false;
  private stopping = false;

  constructor(
    private args: string[],
    private cwd: string,
  ) {}

  get alive(): boolean {
    return this.proc !== null && this.proc.exitCode === null;
  }

  get pid(): number | undefined {
    return this.proc?.pid;
  }

  /** True while an intentional stop/restart is in flight. */
  get isIntentionalStop(): boolean {
    return this.restarting || this.stopping;
  }

  /**
   * Stop the current process (if running), swap args/cwd, and start again.
   * Used for working-directory switches, which pi RPC cannot do in-process.
   */
  async restart(args: string[], cwd: string): Promise<void> {
    this.args = args;
    this.cwd = cwd;
    if (!this.alive) {
      this.start();
      return;
    }
    this.restarting = true;
    try {
      await this.stopAndWait(4000);
    } finally {
      this.restarting = false;
    }
    this.start();
  }

  async stopAndWait(timeoutMs = 4000): Promise<void> {
    const proc = this.proc;
    if (!proc) return;
    this.stopping = true;
    try {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => proc.kill("SIGKILL"), timeoutMs);
        proc.once("exit", () => {
          clearTimeout(timer);
          resolve();
        });
        proc.kill("SIGTERM");
      });
    } finally {
      this.stopping = false;
    }
  }

  start(): void {
    if (this.alive) return;
    let proc: ChildProcessWithoutNullStreams;
    try {
      proc = spawn("pi", this.args, {
        cwd: this.cwd,
        stdio: ["pipe", "pipe", "pipe"],
        env: process.env,
      });
    } catch (err) {
      console.error("[bridge] failed to spawn pi:", err);
      this.onExit(null, null);
      return;
    }
    this.proc = proc;
    this.buffer = "";
    this.onSpawn();

    proc.stdout.on("data", (chunk: Buffer) => this.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      this.stderrTail = (this.stderrTail + text).slice(-4000);
      process.stderr.write(`[pi stderr] ${text}`);
    });
    proc.on("error", (err) => {
      console.error("[bridge] pi process error:", err);
      this.proc = null;
      this.onExit(null, null);
    });
    proc.on("exit", (code, signal) => {
      this.proc = null;
      this.onExit(code, signal);
    });
  }

  private push(chunk: Buffer): void {
    this.buffer += chunk.toString("utf8");
    for (;;) {
      const idx = this.buffer.indexOf("\n");
      if (idx === -1) return;
      let line = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line.length > 0) this.onLine(line);
    }
  }

  send(obj: unknown): boolean {
    if (!this.alive || !this.proc) return false;
    this.proc.stdin.write(JSON.stringify(obj) + "\n");
    return true;
  }

  stop(): void {
    void this.stopAndWait();
  }
}
