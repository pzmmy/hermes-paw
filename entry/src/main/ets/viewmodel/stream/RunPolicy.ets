// =====================================================================
// viewmodel/stream/RunPolicy.ets — §R8 拆分第一片：run 状态判定 + 放弃策略
// EN: Run-state classification and give-up policy (pure functions, extracted from ChatVM).
//
// 纯函数模块：无状态、无 IO、无 hilog。内容从 viewmodel/ChatVM.ets 原样搬出
// （S3a 只搬不改：常量值、判定顺序、注释与理由一字未变）。
// 依赖方向单向：本文件只依赖 model/Run.ets 的 RunStatus，不反向依赖 ChatVM。
// =====================================================================

import { RunStatus } from '../../model/Run';

/** §R3 三条放弃判据（唯一实现点：decideGiveUp）。墙钟不再是放弃条件——
 *  status 仍为 active 就一直等，长任务（模型吐字 5-6 分钟）不再被提前掐断。
 *  ① 连续 K 次 getRun 抛异常/超时（网络断）——连接层事实，不是 run 失败；
 *  ② 连续 M 次返回未知状态（不在终态集也不在 active 集）——协议层异常；
 *  ③ 绝对上限 30min——兜底，run 仍在服务端（可重开取回）。 */
export const GETRUN_FAIL_LIMIT: number = 3;
export const UNKNOWN_STATUS_LIMIT: number = 3;
export const ABSOLUTE_CAP_MS: number = 30 * 60 * 1000;

/** §R3：放弃原因（NONE = 不放弃）。三层原因对应三层 UI 文案，
 *  绝不再一律说「失败」。 */
export enum GiveUpReason {
  NONE = 'none',
  CONNECTION_LOST = 'connection-lost',
  PROTOCOL_ERROR = 'protocol-error',
  ABANDONED_REMOTE = 'abandoned-remote'
}

/** §R3：active 状态集（服务端说在跑 = 不设墙钟）。
 *
 *  ⚠️ 白名单漏状态 = 误收口：baselinePollOnce 的判定顺序是「终态 → active → 否则
 *  unknown」，漏掉一个仍在进行中的状态，run 连续 3 拍（起始 2s 一拍 ≈ 6s）就
 *  被判成 protocol-error 并 finalizeRun——正常请求被 6 秒掐死。
 *  网关新增 run 状态时必须同步此函数与 RunStatus 枚举。
 *  证据：gateway/platforms/api_server_runs.py —— queued 是新 run 初始状态
 *  （_set_run_status(..., "queued") :857/:910）、claimed 为中间态（:1043，
 *  record["status"] in ("queued","claimed")）、stopping 为用户 stop 后终态前
 *  过渡态（_stopping_run_ids :273/:1109）、另有 scheduled / finalizing。
 *  方向原则：拿不准的状态宁可算 active（继续等），unknown 只留给真正不认识
 *  的字符串（协议漂移）。 */
export function isKnownActiveStatus(status: string): boolean {
  return status === RunStatus.PENDING
    || status === RunStatus.QUEUED
    || status === RunStatus.CLAIMED
    || status === RunStatus.SCHEDULED
    || status === RunStatus.RUNNING
    || status === RunStatus.WAITING_APPROVAL
    || status === RunStatus.STOPPING
    || status === RunStatus.FINALIZING;
}

/** §R3 单一放弃判据实现点：只看三个事实，不看「等了多久」。
 *  - 连续 getRun 失败达峰 → 连接层断了（run 未必死）；
 *  - 连续未知状态达峰    → 协议层异常（status 原样作诊断码）；
 *  - 绝对上限 30min      → 兜底，run 仍在服务端。
 *  前两条是「事实判据」：status 仍为 active 时两个计数每拍归零，永不触发；
 *  只有第三条绝对上限能在 active 时结束本轮等待（run 仍在服务端）。
 *  判定顺序：失败 → 未知 → 绝对上限 → NONE（顺序即优先级，勿调换）。 */
export function decideGiveUp(failStreak: number, unknownStreak: number,
  elapsedMs: number): GiveUpReason {
  if (failStreak >= GETRUN_FAIL_LIMIT) {
    return GiveUpReason.CONNECTION_LOST;
  }
  if (unknownStreak >= UNKNOWN_STATUS_LIMIT) {
    return GiveUpReason.PROTOCOL_ERROR;
  }
  if (elapsedMs > ABSOLUTE_CAP_MS) {
    return GiveUpReason.ABANDONED_REMOTE;
  }
  return GiveUpReason.NONE;
}