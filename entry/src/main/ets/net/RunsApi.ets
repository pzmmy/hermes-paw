// =====================================================================
// net/RunsApi.ets — /v1/runs* 族（M1：建 run / 停 / steer / 事件流；M2：审批）
// 契约基准：api-selftest.py W-02/W-03/A 组（全绿）
// =====================================================================

import { http } from '@kit.NetworkKit';
import { ApiClient, ApiError, HttpResult, StreamChunkCallback, StreamEndCallback, StreamErrorCallback } from './ApiClient';
import { RunSnapshot, parseRunSnapshot } from '../model/Run';

/** §R0-3：单次 getRun 的 JS 层硬上限（ms）。到点 ApiClient 直接 destroy 该请求；
 *  基线轮询拍距 2s，3s 上限保证「一拍最多占用一个拍距多一点」，不打乱节奏。 */
const GETRUN_HARD_TIMEOUT_MS: number = 3000;

export class RunsApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  /** POST /v1/runs → 202 {run_id}（W-02a）；body {input, session_id?}
   *  S2-a：input = 纯文本 string（M1 原形）或多模态 OpenAI 风格
   *  messages 数组（model/Multimodal.buildUserMessage，2026-10-31
   *  网关实证）。裸 parts 数组会 400，勿绕过 Multimodal 直接拼。
   *
   *  2026-11-26 幂等：网关已实现标准 Idempotency-Key（见
   *  gateway/platforms/api_server_runs.py:786 读头、:562 同键不同载荷 409、
   *  :551 重放回 Idempotency-Replayed）。同一逻辑发送的网络重试复用同一个键
   *  → 网关回放既有 run，不会再起第二个、不会二次烧 token。
   *  空串 = 不带该头（保持旧行为，兼容性兜底）。 */
  async createRun(input: Object, sessionId: string, idempotencyKey: string): Promise<string> {
    let body: Record<string, Object> = {};
    body['input'] = input;
    if (sessionId !== '') {
      body['session_id'] = sessionId;
    }
    let extra: Record<string, string> | undefined = undefined;
    if (idempotencyKey !== '') {
      let h: Record<string, string> = {};
      h['Idempotency-Key'] = idempotencyKey;
      extra = h;
    }
    let r: HttpResult = await this.client.request(http.RequestMethod.POST, '/v1/runs', body,
      undefined, undefined, undefined, extra);
    let d: Record<string, Object>;
    try {
      d = JSON.parse(r.body);
    } catch (err) {
      let e: Error = err as Error;
      throw new ApiError(r.code, 'invalid JSON in response: ' + String(e.message), r.body);
    }
    let rid: Object | null | undefined = d['run_id'];
    if (rid === null || rid === undefined) {
      throw new ApiError(0, 'run_id missing in response', r.body);
    }
    return String(rid);
  }

  /** GET /v1/runs/{id} → 状态快照（W-02b 轮询基准：1s 间隔）
   *  2026-11-18：显式传 readTimeout=15000。跨机 getRun 实测会挂起（默认 30s
   *  readTimeout 对"无数据半开连接"不生效，实测挂 120s）。15s 作为 SDK 层兜底：
   *  连接建立后 15s 无数据则 SDK 抛超时错误，避免跨机半开连接拖死 recovery
   *  轮询。配合 ChatVM recoverTick 的 Promise.race 10s 竞速（JS 层，更短，
   *  双保险）。
   *  §R0-3（2026-11-18）：再叠一层 3s JS 层硬上限（ApiClient.request 的
   *  hardTimeoutMs）——到点直接 destroy 本请求。基线轮询 2s 一拍，单次
   *  getRun 必须远短于拍距，否则「单次挂 120s × 2s 节奏」会堆成雪崩。
   *  其余接口不传该参数（保持现状）。 */
  async getRun(runId: string): Promise<RunSnapshot> {
    let r: HttpResult = await this.client.request(http.RequestMethod.GET,
      '/v1/runs/' + runId, undefined, 15000, undefined, GETRUN_HARD_TIMEOUT_MS);
    return parseRunSnapshot(r.body, runId);
  }

  /** POST /v1/runs/{id}/stop → 200/202（W-03f） */
  async stop(runId: string): Promise<void> {
    // Explicit type: ArkTS forbids untyped object literals (batch2-r4 P0-02)
    let body: Record<string, string> = {};
    await this.client.request(http.RequestMethod.POST, '/v1/runs/' + runId + '/stop', body);
  }

  /** POST /v1/runs/{id}/steer → 200 {accepted:true}（W-03c）；body {input} */
  async steer(runId: string, input: string): Promise<boolean> {
    let body: Record<string, string> = {};
    body['input'] = input;
    let r: HttpResult = await this.client.request(http.RequestMethod.POST, '/v1/runs/' + runId + '/steer', body);
    let d: Record<string, Object>;
    try {
      d = JSON.parse(r.body);
    } catch (err) {
      let e: Error = err as Error;
      throw new ApiError(r.code, 'invalid JSON in response: ' + String(e.message), r.body);
    }
    let a: Object | null | undefined = d['accepted'];
    return a === true;
  }

  /**
   * POST /v1/runs/{id}/approval（A 组）：三字段缺一不可（A-3 实证 400）。
   * choice：once | deny | session | always（审批窗口 60s，超时自动 deny）
   */
  async approve(runId: string, requestId: string, executionGeneration: number, choice: string): Promise<void> {
    if (executionGeneration < 0) {
      throw new ApiError(0, 'execution_generation negative', ''); // P2-04：防 JSON.stringify 丢字段
    }
    if (choice === '') {
      throw new ApiError(0, 'choice empty', ''); // P2-04
    }
    let body: Record<string, Object> = {};
    body['request_id'] = requestId;
    body['execution_generation'] = executionGeneration;
    body['choice'] = choice;
    await this.client.request(http.RequestMethod.POST, '/v1/runs/' + runId + '/approval', body);
  }

  /**
   * 打开 SSE 事件流 GET /v1/runs/{id}/events（W-02c）。
   * 返回 null = 错误已经 onError 送达，调用方不得持有（P0-02）；
   * 非 null = req 生命周期归调用方，终态必须 destroy。
   */
  /** lastEventId >= 0 时带 Last-Event-ID header（Conduit 借鉴：断线重连重放漏帧）。 */
  openEvents(runId: string, onChunk: StreamChunkCallback, onEnd: StreamEndCallback,
             onError: StreamErrorCallback, lastEventId: number = -1): Promise<http.HttpRequest | null> {
    return this.client.openStream('/v1/runs/' + runId + '/events', onChunk, onEnd, onError, lastEventId);
  }

  /** S5a: 收口时静默取消事件流。 */
  cancelEvents(req: http.HttpRequest | null): void {
    this.client.cancelStream(req);
  }
}
