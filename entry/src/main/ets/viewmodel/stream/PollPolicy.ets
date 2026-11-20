/**
 * 基线轮询的自适应节拍（S7a：从 ChatVM 抽出，纯函数、无副作用）。
 * 语义与抽出前逐字等价：连续 3 轮 output 无变化 → 间隔翻倍，封顶 5000ms。
 */
export const POLL_START_MS: number = 2000;
export const POLL_MAX_MS: number = 5000;
export const POLL_SSE_ACTIVE_MS: number = 10000;
export const POLL_IDLE_ROUNDS_TO_DOUBLE: number = 3;

/**
 * @param current 当前拍距（ms）
 * @param idleRounds 连续无变化轮数（调用方已 +1 后的值）
 * @returns 下一拍距；未达阈值或已封顶时原样返回 current
 */
export function nextPollInterval(current: number, idleRounds: number): number {
  if (idleRounds < POLL_IDLE_ROUNDS_TO_DOUBLE) {
    return current;
  }
  if (current >= POLL_MAX_MS) {
    return current;
  }
  const doubled: number = current * 2;
  return doubled > POLL_MAX_MS ? POLL_MAX_MS : doubled;
}