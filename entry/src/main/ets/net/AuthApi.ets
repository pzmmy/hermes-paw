// =====================================================================
// net/AuthApi.ets — /api/auth/* 族（P2 用户登录：发码/校验/会话自省/登出）
// 契约基准：tools/auth-selftest.py（26/26 全绿，2026-11-16 两解释器）
//   request-code → 202 {sent: true, ttl_s}
//   verify       → 200 {user: {id, email, display_name}, session_token}
//   me           → 200 {user, session: {expires_at}} / 401 invalid_session
//   logout       → 204 / 401 invalid_session
//   错误体       → {error: {message, code}}
// D3：/api/auth/* 豁免会话门；request-code/verify 亦不要求网关 Bearer
// 密钥（自测实证）——登录页在"有 profile、未登录"时即可用。
// =====================================================================

import { http } from '@kit.NetworkKit';
import { ApiClient, ApiError, HttpResult } from './ApiClient';

export class AuthApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  /** POST /api/auth/request-code {email} → 202 {sent, ttl_s}。
   *  失败抛 ApiError（400 invalid_email / 429 rate_limited /
   *  502 smtp_unavailable / 网络级）。 */
  async requestCode(email: string): Promise<void> {
    let body: Record<string, string> = {};
    body['email'] = email;
    await this.client.request(http.RequestMethod.POST, '/api/auth/request-code', body);
  }

  /** POST /api/auth/verify {email, code} → 200 {user, session_token}。
   *  返回会话令牌（验证码服务端一次性消费，失败即不可重试原码）。 */
  async verify(email: string, code: string): Promise<string> {
    let body: Record<string, string> = {};
    body['email'] = email;
    body['code'] = code;
    let r: HttpResult = await this.client.request(http.RequestMethod.POST, '/api/auth/verify', body);
    let d: Record<string, Object>;
    try {
      d = JSON.parse(r.body) as Record<string, Object>;
    } catch (err) {
      let e: Error = err as Error;
      throw new ApiError(r.code, 'invalid JSON in response: ' + String(e.message), r.body);
    }
    let t: Object | null | undefined = d['session_token'];
    if (t === null || t === undefined || String(t) === '') {
      throw new ApiError(0, 'session_token missing in response', r.body);
    }
    return String(t);
  }

  /** GET /api/auth/me → 200 {user, session{expires_at}}（有效并滑动 TTL）。
   *  401 以 ApiError 抛出——调用方区分"未登录"与"令牌失效"。 */
  async me(): Promise<void> {
    await this.client.request(http.RequestMethod.GET, '/api/auth/me');
  }

  /** POST /api/auth/logout → 204（立即且幂等吊销）。 */
  async logout(): Promise<void> {
    let body: Record<string, string> = {};
    await this.client.request(http.RequestMethod.POST, '/api/auth/logout', body);
  }
}

/** 错误体 {error:{message,code}} 中的 code 字段；无/不可解析 → ''。 */
export function authErrorCode(e: ApiError): string {
  let raw: string = e.rawBody;
  if (raw === '') {
    return '';
  }
  try {
    let d: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    let errObj: Object | null | undefined = d['error'];
    if (errObj === null || errObj === undefined) {
      return '';
    }
    let inner: Record<string, Object> = errObj as Record<string, Object>;
    let c: Object | null | undefined = inner['code'];
    if (c === null || c === undefined) {
      return '';
    }
    return String(c);
  } catch (err) {
    return '';
  }
}
