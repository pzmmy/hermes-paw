// =====================================================================
// net/ErrorText.ets — unified user-facing error wording (S3-a)
//
// D1 wording table (S3 plan §2, approved 2026-11-01). Callers prepend
// the operation prefix (e.g. '发送失败：'), so each body is reason +
// one action, no leading verb. Raw error details stay in hilog only —
// never shown verbatim (one plain sentence + one action, plan §7.6-1).
//
// Code mapping (ApiError.code sources, ApiClient.ets):
//   401                HTTP 401 from the gateway (bad/expired token)
//   500..599           server-side failure
//   -2                 our own SSE idle watchdog (ApiClient)
//   -1                 not configured (ApiClient)
//   0                  transport-level failure with no code
//   2300000..2399999   @ohos.net.http BusinessError range — the
//                      "HTTP 000" family as it actually surfaces on
//                      device (connect failed / timeout / reset),
//                      e.g. 2300006
//   anything else      generic fallback with the code
// =====================================================================

import { Msg } from '../utils/Msg';
import { ApiError } from './ApiClient';

/** Plain-language body (reason + one action) for an ApiError. */
export function describeApiError(e: ApiError): string {
  let c: number = e.code;
  if (c === 401) {
    return Msg.t('m_err_token');
  }
  if (c >= 500 && c < 600) {
    return Msg.t('m_err_server');
  }
  if (c === -2) {
    return Msg.t('m_err_timeout');
  }
  if (c === -1) {
    return Msg.t('m_err_no_addr');
  }
  if (c === 0) {
    return Msg.t('m_err_unreachable');
  }
  if (c >= 2300000 && c < 2400000) {
    return Msg.t('m_err_unreachable');
  }
  return Msg.t('m_err_req_fail_prefix') + String(c) + Msg.t('m_err_req_fail_suffix');
}

/**
 * Tolerant variant for mixed catch blocks: ApiError gets the D1
 * wording; anything else (local DB / pasteboard / ASR) falls back to
 * the raw message — those are non-network and out of the D1 scope.
 */
export function describeError(err: Error): string {
  if (err instanceof ApiError) {
    return describeApiError(err);
  }
  return err.message;
}

// =====================================================================
// Conduit 借鉴：stream 错误分类（hermes_error_surface.dart HermesErrorKind）
//
// 把"一锅烩"的 stream 错误分成 5 种，每种有独立的 UI 文案和处理策略：
//   stream_drop   跨机丢帧/断线（可重连，带 Last-Event-ID 重放）
//   auth          Token 过期/无效（需重新登录）
//   timeout       连接超时（模型慢或服务端卡）
//   server_error  服务端 5xx（需重试）
//   unknown       其他（兜底）
//
// ChatVM.onStreamError 按分类决定：重连 / 报错 / 继续轮询。
// =====================================================================

export enum StreamErrorKind {
  STREAM_DROP = 'stream_drop',
  AUTH = 'auth',
  TIMEOUT = 'timeout',
  SERVER_ERROR = 'server_error',
  UNKNOWN = 'unknown'
}

/** 分类一个 stream 错误（ApiError.code → StreamErrorKind）。
 *  映射规则（对照 Conduit HermesErrorKind + 我们 ApiClient 错误码）：
 *   -2 (SSE idle watchdog) → STREAM_DROP（跨机丢帧）
 *   0 / 2300xxx (transport) → STREAM_DROP（网络断）
 *   401 (auth) → AUTH
 *   408 (request timeout) → TIMEOUT
 *   500-599 → SERVER_ERROR
 *   其他 → UNKNOWN */
export function classifyStreamError(err: ApiError): StreamErrorKind {
  let c: number = err.code;
  if (c === -2 || c === 0 || (c >= 2300000 && c < 2400000)) {
    return StreamErrorKind.STREAM_DROP;
  }
  if (c === 401) {
    return StreamErrorKind.AUTH;
  }
  if (c === 408 || c === -3) {
    return StreamErrorKind.TIMEOUT;
  }
  if (c >= 500 && c < 600) {
    return StreamErrorKind.SERVER_ERROR;
  }
  return StreamErrorKind.UNKNOWN;
}

/** 按分类返回 UI 文案（比 describeApiError 更精准）。
 *  与 i18n 键 stream_err_* 一一对应（待加 string.json）。 */
export function describeStreamError(kind: StreamErrorKind): string {
  switch (kind) {
    case StreamErrorKind.STREAM_DROP:
      return Msg.t('m_err_interrupted');
    case StreamErrorKind.AUTH:
      return Msg.t('m_err_login_expired');
    case StreamErrorKind.TIMEOUT:
      return Msg.t('m_err_resp_timeout');
    case StreamErrorKind.SERVER_ERROR:
      return Msg.t('m_err_server');
    default:
      return Msg.t('m_err_conn');
  }
}
