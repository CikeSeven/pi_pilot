/**
 * 按 source 串行化会话结构命令。
 *
 * 与租约无关,**必须做**:pi 的 RPC 入口是 `void handleInputLine(line)`
 * ——即发即忘、无背压。两条 fork/switch_session 在同一进程里交错执行会真的
 * 损坏运行时状态(会话文件被两个写入方交替 append)。租约只能保证"同一时刻
 * 只有一个客户端在驱动",挡不住同一个客户端连点两次,也挡不住电脑端与手机
 * 端各自发一条。
 */
export class CommandQueue {
  private readonly tails = new Map<string, Promise<unknown>>();

  /** 该 source 上是否有命令正在排队/执行。 */
  busy(key: string): boolean {
    return this.tails.has(key);
  }

  /** 把 task 接到该 key 的队尾;前一条无论成败都不阻塞后一条。 */
  run<T>(key: string, task: () => Promise<T>): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve();
    const next = previous.then(task, task);
    // 记住当前队尾;它完成时如果没有更后面的任务就清理,避免 map 无限增长
    const tail = next.then(
      () => undefined,
      () => undefined,
    );
    this.tails.set(key, tail);
    void tail.then(() => {
      if (this.tails.get(key) === tail) this.tails.delete(key);
    });
    return next;
  }
}
