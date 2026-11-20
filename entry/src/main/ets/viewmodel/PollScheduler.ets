// viewmodel/PollScheduler.ets —— 基线轮询调度器（§R0）
// EN: owns the baseline polling *mechanism*: the setInterval ticker, the
//     in-flight guard (at most one getRun in flight), the run identity being
//     polled, the current interval, and the 1s elapsed counter.
//
// 从 ChatVM 抽出来的只是机制，不含任何判定语义：
//   · 什么时候该放弃（连接层失败 / 未知状态 / 30min 绝对上限）——留在 ChatVM
//   · 快照怎么归并、气泡怎么去重、收口怎么收——留在 ChatVM
// 这里只保证四条不变量：
//   1. 同一时刻只有一条 ticker（start/rearm 都会先清旧句柄）
//   2. 同一 run 在飞 getRun ≤ 1（tryEnter/leave 守卫，调用方拿不到就跳过本拍）
//   3. 拍距可变（rearm），但只在运行中生效
//   4. stop 之后所有状态归零（runId/startAt/inFlight/elapsed）
//
// 为什么用一条 setInterval 而不是嵌套 setTimeout：ArkTS async 下嵌套定时器
// 竞速实测不可靠（S3-b 之前的 recovery 通道就是因此废弃的）。

/** 等待期已用秒数的推进间隔（UI 状态条每秒刷新）。 */
const ELAPSED_TICK_MS: number = 1000;

export class PollScheduler {
  private tickerId: number = -1;
  private elapsedId: number = -1;
  private inFlight: boolean = false;
  private intervalMs: number = 0;
  private runId: string = '';
  private startAt: number = 0;
  private elapsed: number = 0;

  /** 每个拍距到点回调（参数为当前 runId）。 */
  onTick: (rid: string) => void = (rid: string): void => {
  };
  /** 每秒回调（参数为已用秒数）。 */
  onElapsed: (sec: number) => void = (sec: number): void => {
  };

  /** 开跑：清旧句柄 → 记 run 身份 → 建 ticker + 秒表。 */
  start(rid: string, intervalMs: number): void {
    this.stop();
    this.runId = rid;
    this.intervalMs = intervalMs;
    this.startAt = Date.now();
    this.elapsed = 0;
    this.arm();
    this.elapsedId = setInterval((): void => {
      this.elapsed = this.elapsed + 1;
      this.onElapsed(this.elapsed);
    }, ELAPSED_TICK_MS);
  }

  /** 按当前 intervalMs 建/重建 ticker（内部用）。 */
  private arm(): void {
    if (this.tickerId !== -1) {
      clearInterval(this.tickerId);
      this.tickerId = -1;
    }
    this.tickerId = setInterval((): void => {
      this.onTick(this.runId);
    }, this.intervalMs);
  }

  /** 换拍距（自适应降频 / SSE 活跃提速）。未运行时不做事。 */
  rearm(intervalMs: number): void {
    if (this.tickerId === -1) {
      return;
    }
    if (intervalMs === this.intervalMs) {
      return;
    }
    this.intervalMs = intervalMs;
    this.arm();
  }

  /** 停机并归零。幂等。 */
  stop(): void {
    if (this.tickerId !== -1) {
      clearInterval(this.tickerId);
      this.tickerId = -1;
    }
    if (this.elapsedId !== -1) {
      clearInterval(this.elapsedId);
      this.elapsedId = -1;
    }
    this.inFlight = false;
    this.runId = '';
    this.startAt = 0;
    this.elapsed = 0;
  }

  /** 并发守卫：拿到 true 才允许发 getRun，处理完必须 leave()。 */
  tryEnter(): boolean {
    if (this.inFlight) {
      return false;
    }
    this.inFlight = true;
    return true;
  }

  /** 释放并发守卫（无论成功失败都要调）。 */
  leave(): void {
    this.inFlight = false;
  }

  isRunning(): boolean {
    return this.tickerId !== -1;
  }

  getRunId(): string {
    return this.runId;
  }

  getIntervalMs(): number {
    return this.intervalMs;
  }

  /** 本轮轮询起算时刻（30min 绝对上限的基准）。 */
  getStartAt(): number {
    return this.startAt;
  }

  getElapsedSec(): number {
    return this.elapsed;
  }
}
