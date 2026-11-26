// =====================================================================
// net/ApiClient.ets — 统一 HTTP 客户端（M1）
// EN: Unified HTTP client (bearer auth, timeouts, SSE watchdogs, request cancellation).
//
// 契约基准：tools/api-selftest.py（21 用例全绿，2026-10-27；r2 统一口径：SUMMARY 按 check() 计数）
//   认证：Authorization: Bearer ***
//   角色：X-Hermes-Session-Key（M1 固定 default，M4 多角色）
//   /p/<pf>/ profile 前缀：S1 启用（pf 非空时所有 path 加 '/p/<pf>/'；
//     P-01 已实证 /p/default/v1/capabilities 形态。pf 来自扫码串，与
//     role 正交：role 走 X-Hermes-Session-Key header，pf 走 URL）
// HTTP 栈：@kit.NetworkKit http（系统 API，零第三方依赖，§4.2）
//
// 流式错误契约（2026-10-27 测爷一轮签发修复，P0-01/P0-02/P1-02）：
//   - HttpRequest 无 'error' 事件（官方 d.ts 全部 6 个 on 重载已核对），
//     错误收敛到 requestInStream().catch()；静默挂死由空闲看门狗覆盖
//   - openStream 必 settle：成功 resolve(req)；失败 destroy + onError +
//     resolve(null)；调用方不得持有 null
//   - onEnd 透传真实响应码（不硬编码 200）；「连接结束 ≠ run 结束」，
//     run 终态由业务层终态帧判定（批次2 SseParser）
// =====================================================================

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { normPf } from '../model/LocalSession';
import { LogSafe } from '../utils/LogSafe';

const TAG: string = 'ApiClient';
/** 【分工】两个超时各管一层，不要混淆：
 *  - SSE_READ_TIMEOUT_MS：鸿蒙 SDK 层硬超时（http.createHttp 的 readTimeout），
 *    决定底层会不会主动杀流；它一触发就是 onStreamError(code=2300028)，
 *    我们的代码无法拦截，只能事后恢复。
 *  - SSE_IDLE_TIMEOUT_MS：我们自己 JS 层的空闲看门狗（无数据 N 毫秒 → 兜底
 *    destroy + onError）。它是兜底，必须比 READ 短，先由它做可控善后，
 *    而不是让 SDK 硬超时先动手。
 *
 *  实测证据（2026-11-19 09:46~09:48，真机）：长问题 9487 字，t≈30s 时报
 *  stream error kind=stream_drop code=2300028，而此时 getRun 仍返回 run=running；
 *  之后流彻底死掉，用户空等约 70s，直到终态才由轮询一次性拿到 9487 字。
 *  模型思考期本身就可能 >30s 零帧，所以 30s 的读超时会把「还活着的流」判死。
 *
 *  IDLE 30s→120s：覆盖模型思考期的零帧空窗，让看门狗不再抢先误杀。 */
const SSE_IDLE_TIMEOUT_MS: number = 120000;
/** SSE 读超时 30s→180s：给 SDK 层留出足够余量，避免 run 仍在 running 时把流杀掉
 *  （2300028，见上方实测证据）。必须显著大于 IDLE（120s），保证
 *  「我们的看门狗先触发、SDK 硬超时后触发」这个顺序成立。 */
const SSE_READ_TIMEOUT_MS: number = 180000;
/** API 契约版本标记（Option B 关于区展示；/health 无鉴权兼容探针同源，batch2-r7）。
 *  协议演进时递增，设置页「API 契约版本」行只读展示。 */
export const API_CONTRACT_VERSION: string = 'v1';

/** 通用 HTTP 结果（body 保持原文，JSON 解码按需） */
export interface HttpResult {
  code: number;
  body: string;
  contentType: string;
}

/** 业务错误（含非 2xx 与网络层失败）.
 *  Extends Error: ArkTS arkts-limited-throw requires the thrown value to
 *  be an instance of Error or a subclass (batch2-r4 P0-01). */
export class ApiError extends Error {
  code: number;
  rawBody: string;

  constructor(code: number, message: string, rawBody: string) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.rawBody = rawBody;
  }
}

/** SSE 回调类型（原始字节块，帧切分在 SseParser） */
export type StreamChunkCallback = (chunk: ArrayBuffer) => void;
/** onEnd(code)：code = requestInStream 透传的真实 HTTP 响应码（不硬编码） */
export type StreamEndCallback = (code: number) => void;
export type StreamErrorCallback = (err: ApiError) => void;

/** 单次请求结果（内部）：ok=false 且 serverCode>0 = 服务端应答非 2xx（不重试）
 *  hardTimedOut=true = JS 层硬上限到点被 destroy（§R0-3，调用方不再重试） */
interface AttemptOutcome {
  ok: boolean;
  serverCode: number;
  message: string;
  rawBody: string;
  result?: HttpResult;
  hardTimedOut?: boolean;
}

/** Conduit 借鉴（iHermes AbortController 思路）：鸿蒙 http.HttpRequest 没有
 *  原生 AbortController，但有等价的 req.destroy() 机制。openStream 内部已
 *  有 doDestroy()（line 174）在错误/终态时清理。ChatVM 通过持有的
 *  streamReq 引用可随时 destroy() 主动取消（用户点"停止"按钮）。
 *  超时由 SSE_IDLE_TIMEOUT_MS 看门狗 + readTimeout 双重保障。
 *  本类不需要额外的 AbortController 封装——现有 destroy() 已等价。 */
export class ApiClient {
  baseUrl: string = '';
  role: string = 'default';
  /** profile prefix（S1）：非空 -> 所有 path 加 '/p/<pf>/' */
  pf: string = '';
  private token: string = '';
  /** P2: 用户会话令牌（X-User-Session header）。与网关密钥（Authorization
   *  Bearer）正交——D1=A 双层认证。'' = 无用户会话（P2 前客户端 / 无
   *  auth 网关）。configure() 不触碰本字段：VM 在 configure 之后从
   *  TokenVault 恢复（见 ChatVM.connect）。 */
  userSession: string = '';

  /** S5a: openStream 的空闲看门狗活在闭包里，外部 destroy 无法清它。
   *  这里登记每个流请求的「静默取消」闭包，供 ChatVM 收口时调用。 */
  private streamCancelers: Map<http.HttpRequest, () => void> = new Map();

  /** 切换服务器（token 只入内存；持久化走 TokenVault，P1-4）。
   *  pf: profile prefix（'' = 无前缀；'default' 归一为 ''，normPf） */
  configure(baseUrl: string, token: string, role: string, pf: string): void {
    this.baseUrl = trimTrailingSlash(baseUrl);
    this.token = token;
    this.role = role;
    this.pf = normPf(pf);
  }

  /** P2: 挂载/摘除用户会话令牌（'' = 摘除）。 */
  setUserSession(s: string): void {
    this.userSession = s;
  }

  private buildUrl(path: string): string {
    if (this.pf !== '') {
      return this.baseUrl + '/p/' + this.pf + path;
    }
    return this.baseUrl + path;
  }

  private baseHeaders(): Record<string, string> {
    let h: Record<string, string> = {};
    if (this.token !== '') {
      h['Authorization'] = 'Bearer ' + this.token; // 未配置 token 不发空 Bearer（P2-15）
    }
    h['X-Hermes-Session-Key'] = this.role;
    if (this.userSession !== '') {
      h['X-User-Session'] = this.userSession; // P2: 双层认证（D1=A）
    }
    return h;
  }

  /**
   * 一次性 JSON 请求（非流式）。
   * 重试：仅网络层失败（服务端 4xx/5xx 不重试）；幂等 GET 默认重试 1 次（800ms 间隔）；
   * 大响应调用方传 noRetry=true 避免整包重下（P2-07）。
   * hardTimeoutMs（§R0-3）：单次请求的 JS 层硬上限，到点必须 destroy 该请求——
   * 不依赖 SDK readTimeout（RunsApi.ets:43 实测对「无数据半开连接」不生效）。
   * undefined = 不设硬上限（保持既有行为）。
   */
  async request(method: http.RequestMethod, path: string, body?: Object,
                readTimeoutMs?: number, noRetry?: boolean,
                hardTimeoutMs?: number,
                extraHeaders?: Record<string, string>): Promise<HttpResult> {
    if (this.baseUrl === '') {
      throw new ApiError(-1, 'not configured', ''); // P2-15
    }
    let rt: number = (readTimeoutMs === undefined) ? 30000 : readTimeoutMs;
    let retry: boolean = (noRetry === undefined) ? true : !noRetry;
    let attempts: number = (method === http.RequestMethod.GET && retry) ? 2 : 1;
    let last: AttemptOutcome = { ok: false, serverCode: 0, message: 'not attempted', rawBody: '' };
    for (let i = 0; i < attempts; i++) {
      last = await this.doOnce(method, path, body, rt, hardTimeoutMs, extraHeaders);
      if (last.ok) {
        if (last.result === undefined) {
          throw new ApiError(0, 'no result', last.rawBody); // 防回归（P2-06）
        }
        return last.result;
      }
      if (last.serverCode > 0) {
        break; // 服务端已应答：不重试
      }
      // §R0-3：硬上限超时的请求不再重试——调用方（基线轮询）按 tick 节奏重试，
      // 此处重试会让单次占用翻倍，破坏「同一 run 在飞 ≤1」。
      if (last.hardTimedOut) {
        break;
      }
      if (i < attempts - 1) {
        await this.delay(800 * (i + 1));
      }
    }
    throw new ApiError(last.serverCode, last.message, last.rawBody);
  }

  /**
   * 打开流式请求（SSE 事件流）。
   * 返回 Promise<http.HttpRequest | null>（P0-02 三态）：
   *   - 非 null：流已建立，req 生命周期归调用方，终态必须 destroy
   *   - null：已 destroy + onError(err)，调用方不得持有
   * 全部错误路径（非 2xx / 连接 / 空闲超时）=「destroy + onError + resolve(null)」，
   * Promise 必 settle 且只 settle 一次；流建立后的错误（空闲超时）只走 onError，
   * 不再动 Promise（已 resolve(req)）。
   * 静默挂死覆盖：无 'error' 事件且半开连接不触发 dataEnd，由空闲看门狗
   * （SSE_IDLE_TIMEOUT_MS 无数据）兜底 destroy + onError。
   */
  /** openStream with optional Last-Event-ID header (Conduit 借鉴：断线重连时
   *  传 lastSeq，服务端重放 seq > lastSeq 的漏帧，恢复逐字输出而非只拿快照）。
   *  lastEventId < 0 表示新流（不带 header）。 */
  openStream(path: string, onChunk: StreamChunkCallback, onEnd: StreamEndCallback,
             onError: StreamErrorCallback, lastEventId: number = -1): Promise<http.HttpRequest | null> {
    if (this.baseUrl === '') {
      // P2-16 (r2): align with request() guard; error path = onError + resolve(null)
      let err: ApiError = new ApiError(-1, 'not configured', '');
      onError(err);
      return Promise.resolve(null);
    }
    return new Promise<http.HttpRequest | null>((resolve) => {
      let req: http.HttpRequest = http.createHttp();
      let respCode: number = 0;
      let streamReady: boolean = false;
      let terminated: boolean = false;
      let destroyed: boolean = false;
      let idleTimerId: number = -1;

      const doDestroy = (): void => {
        if (!destroyed) {
          destroyed = true;
          req.destroy();
        }
      };

      const clearIdle = (): void => {
        if (idleTimerId !== -1) {
          clearTimeout(idleTimerId);
          idleTimerId = -1;
        }
      };

      /** 终态（至多一次）：destroy + onError + resolve(null) */
      const finishError = (err: ApiError): void => {
        if (terminated) {
          return;
        }
        terminated = true;
        clearIdle();
        doDestroy();
        this.streamCancelers.delete(req); // S5a: 终态撤登记，外部 cancelStream 变 no-op
        onError(err);
        resolve(null); // 若 Promise 已 resolve(req) 此为 no-op；错误通道统一 onError
      };

      const armIdle = (): void => {
        clearIdle();
        idleTimerId = setTimeout((): void => {
          finishError(new ApiError(-2, 'SSE idle timeout', ''));
        }, SSE_IDLE_TIMEOUT_MS);
      };

      let headers: Record<string, string> = this.baseHeaders();
      headers['Accept'] = 'text/event-stream';
      // Conduit 借鉴：断线重连时带 Last-Event-ID，服务端从 lastSeq+1 重放漏帧
      if (lastEventId >= 0) {
        headers['Last-Event-ID'] = String(lastEventId);
      }
      req.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (terminated || !streamReady) {
          return; // 非 2xx 的 error body 块不透传
        }
        onChunk(chunk);
        armIdle(); // 每来数据复位空闲看门狗
      });
      req.on('dataEnd', (): void => {
        if (terminated || !streamReady) {
          return; // 响应码未 settle（非 2xx body 结束）：码路径由 .then 处理
        }
        terminated = true;
        clearIdle();
        doDestroy();
        this.streamCancelers.delete(req); // S5a: 流自然结束，撤登记
        onEnd(respCode); // 透传真实响应码（P1-02①）；run 是否终态由业务层判定
      });
      // S5a: 登记静默取消闭包——terminated/idleTimerId 都在本闭包内，
      // 只能在这里置位；外部 destroy 清不掉已 arm 的 JS 定时器。
      this.streamCancelers.set(req, (): void => {
        if (terminated) {
          return;
        }
        terminated = true;
        clearIdle();
        doDestroy();
      });
      req.requestInStream(this.buildUrl(path), {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: SSE_READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false
      }).then((code: number): void => {
        if (code < 200 || code >= 300) {
          finishError(new ApiError(code, 'HTTP ' + code, ''));
          return;
        }
        respCode = code;
        streamReady = true;
        armIdle(); // 流建立即开始空闲看门狗
        resolve(req);
      }).catch((e: BusinessError): void => {
        LogSafe.w(TAG, 'requestInStream failed: code=%{public}d message=%{public}s',
          Number(e.code), String(e.message));
        finishError(new ApiError(Number(e.code), String(e.message), ''));
      });
    });
  }

  /** S5a: 静默取消流（收口用）——不触发 onError/onEnd，只停看门狗 + destroy req。 */
  cancelStream(req: http.HttpRequest | null): void {
    if (req === null) {
      return;
    }
    let cancel: (() => void) | undefined = this.streamCancelers.get(req);
    this.streamCancelers.delete(req);
    if (cancel !== undefined) {
      cancel();
    } else {
      try {
        req.destroy();
      } catch (err) {
        LogSafe.d(TAG, 'cancelStream: req already destroyed');
      }
    }
  }

  private async doOnce(method: http.RequestMethod, path: string, body: Object | undefined,
                       readTimeoutMs: number, hardTimeoutMs?: number,
                       extraHeaders?: Record<string, string>): Promise<AttemptOutcome> {
    let req: http.HttpRequest = http.createHttp();
    // §R0-3：JS 层硬上限（仅当调用方传 hardTimeoutMs）。
    let hardTimerId: number = -1;
    let hardFired: boolean = false;
    try {
      let headers: Record<string, string> = this.baseHeaders();
      if (body !== undefined) {
        headers['Content-Type'] = 'application/json';
      }
      // 调用方自定义头（如 POST /v1/runs 的 Idempotency-Key）。放在 baseHeaders
      // 之后覆盖：调用方的意图优先，且不引入第二套头拼装逻辑。
      if (extraHeaders !== undefined) {
        let keys: string[] = Object.keys(extraHeaders);
        for (let i = 0; i < keys.length; i++) {
          headers[keys[i]] = extraHeaders[keys[i]];
        }
      }
      let reqP: Promise<http.HttpResponse> = req.request(this.buildUrl(path), {
        method: method,
        header: headers,
        extraData: (body === undefined) ? undefined : JSON.stringify(body),
        connectTimeout: 10000,
        readTimeout: readTimeoutMs,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      });
      // 硬上限先输（race 输方）时 reqP 的 reject 必须被消费，否则会成为未处理拒绝。
      reqP.catch((err: Error): void => {
        LogSafe.d(TAG, 'request rejected after hard timeout: %{public}s', err.message);
      });
      let resp: http.HttpResponse;
      if (hardTimeoutMs === undefined || hardTimeoutMs <= 0) {
        resp = await reqP;
      } else {
        // §R0-3 单次请求硬上限：到点 destroy 该请求，不靠 SDK readTimeout（对半开
        // 连接实测无效）。destroy 之外再用 JS 竞速，保证 await 必 settle。
        let limitMs: number = hardTimeoutMs;
        let timeoutP: Promise<Error> = new Promise<Error>((resolve): void => {
          hardTimerId = setTimeout((): void => {
            hardFired = true;
            try {
              req.destroy();
            } catch (err) {
              let de: BusinessError = err as BusinessError;
              LogSafe.w(TAG, 'hard-timeout destroy failed: code=%{public}d', de.code);
            }
            resolve(new Error('hard timeout ' + limitMs + 'ms'));
          }, limitMs);
        });
        let raced: Object = await Promise.race([reqP, timeoutP]) as Object;
        if (raced instanceof Error) {
          throw raced as Error;
        }
        resp = raced as http.HttpResponse;
      }
      let out: AttemptOutcome = { ok: false, serverCode: 0, message: '', rawBody: '' };
      let r: Object | null | undefined = resp.result;
      out.rawBody = (r === null || r === undefined) ? '' : String(r);
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        out.ok = true;
        out.result = { code: resp.responseCode, body: out.rawBody, contentType: this.contentType(resp) };
      } else {
        out.serverCode = resp.responseCode;
        out.message = 'HTTP ' + resp.responseCode;
      }
      return out;
    } catch (err) {
      let e = err as BusinessError;
      let out: AttemptOutcome = { ok: false, serverCode: 0, message: '', rawBody: '' };
      out.hardTimedOut = hardFired; // §R0-3：硬上限超时不重试
      out.message = (hardFired ? 'hard timeout: ' : 'network error: ')
        + String(e.code) + ' ' + String(e.message);
      return out;
    } finally {
      if (hardTimerId !== -1) {
        clearTimeout(hardTimerId);
        hardTimerId = -1;
      }
      req.destroy();
    }
  }

  private contentType(resp: http.HttpResponse): string {
    let h: Record<string, Object> = resp.header as Record<string, Object>;
    let v: Object | null | undefined = h['Content-Type'];
    if (v === null || v === undefined) {
      return '';
    }
    return String(v);
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }
}

function trimTrailingSlash(s: string): string {
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
