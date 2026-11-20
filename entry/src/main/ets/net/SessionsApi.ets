// =====================================================================
// net/SessionsApi.ets — /api/sessions*（M1：新建会话 + 历史重开 + 全量重拉；M5：搜索）
// 响应形状（R-05 / S-01 实证）：{data: [...]}
// 字段类型：selftest 仅断言数量，未断言字段类型 → 宽松解析（P2-03）
// =====================================================================

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { ApiClient, ApiError, HttpResult } from './ApiClient';
import { ServerMessage, parseServerMessages, strFrom, numFrom } from '../model/ChatMessage';

const TAG: string = 'SessionsApi';

/** 会话摘要（GET /api/sessions data[] 子集，R-05 实证；id 宽松解析，selftest 未断言） */
export interface SessionInfo {
  id: string;
  title: string;
  preview: string;
  last_active: number;
  message_count: number;
  model: string;
  source: string;
  archived: boolean;
  hidden: boolean;
  pinned: boolean;
}

function boolFrom(v: Object | null | undefined): boolean {
  return v === true;
}

/** 宽容解析 GET /api/sessions 响应 */
export function parseSessionInfos(body: string): SessionInfo[] {
  let out: SessionInfo[] = [];
  try {
    let d: Record<string, Object> = JSON.parse(body);
    let arrObj: Object | null | undefined = d['data'];
    if (arrObj === null || arrObj === undefined || !(arrObj instanceof Array)) {
      return out;
    }
    let arr: Record<string, Object>[] = arrObj as Record<string, Object>[];
    for (let i = 0; i < arr.length; i++) {
      let s: Record<string, Object> = arr[i];
      let idRaw: Object | null | undefined = s['id'];
      if (idRaw === null || idRaw === undefined) {
        LogSafe.w(TAG, 'session id missing (selftest unasserted, lenient)');
      }
      let info: SessionInfo = {
        id: strFrom(s['id']),
        title: strFrom(s['title']),
        preview: strFrom(s['preview']),
        last_active: numFrom(s['last_active']),
        message_count: numFrom(s['message_count']),
        model: strFrom(s['model']),
        source: strFrom(s['source']),
        archived: boolFrom(s['archived']),
        hidden: boolFrom(s['hidden']),
        pinned: boolFrom(s['pinned'])
      };
      out.push(info);
    }
  } catch (err) {
    let e: BusinessError = err as BusinessError;
    LogSafe.w(TAG, 'sessions parse failed, lenient: %{public}s', String(e.message));
  }
  return out;
}

export class SessionsApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  /** GET /api/sessions → 会话列表（R-05：200 {data:[...]}） */
  async listSessions(): Promise<SessionInfo[]> {
    // S9a-2b：服务端默认 limit=50，而网关已累积近千条会话 —— 不显式放大就会漏掉最新几条
    let r: HttpResult = await this.client.request(http.RequestMethod.GET, '/api/sessions?limit=200');
    return parseSessionInfos(r.body);
  }

  /**
   * POST /api/sessions → 201 {session: {id}}（W-01）；body {title}。
   * M1 新会话入口：先建会话，再以 sid 调 createRun(input, sid)。
   */
  async createSession(title: string): Promise<string> {
    let body: Record<string, string> = {};
    // S9a：title 留空时**不发**该字段，交给网关按首条消息自动命名
    // （derive_title 派生 → llm 升级 3-7 词）。自造占位名会以非 derived
    // 权威落库，把自动命名永久封死（impl-status §2.7）。
    if (title !== '') {
      body['title'] = title;
    }
    let r: HttpResult = await this.client.request(http.RequestMethod.POST, '/api/sessions', body);
    let d: Record<string, Object>;
    try {
      d = JSON.parse(r.body);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'createSession: invalid JSON (HTTP %{public}d): %{public}s',
        r.code, String(e.message));
      throw new ApiError(r.code, 'invalid JSON in response', r.body);
    }
    let sessRaw: Object | null | undefined = d['session'];
    if (sessRaw === null || sessRaw === undefined) {
      throw new ApiError(0, 'session missing in response', r.body);
    }
    let sess: Record<string, Object> = sessRaw as Record<string, Object>;
    let sidRaw: Object | null | undefined = sess['id'];
    if (sidRaw === null || sidRaw === undefined) {
      throw new ApiError(0, 'session.id missing in response', r.body);
    }
    return String(sidRaw);
  }

  /**
   * GET /api/sessions/{id}/messages → 全量消息重拉（S-01）。
   * 长会话（200+ 条）可能 >2MB：读超时放宽 60s；
   * noRetry=true：大响应不重试，避免整包重下（P2-07）。
   */
  async fetchMessages(sessionId: string): Promise<ServerMessage[]> {
    let r: HttpResult = await this.client.request(
      http.RequestMethod.GET, '/api/sessions/' + sessionId + '/messages', undefined, 60000, true);
    return parseServerMessages(r.body);
  }

  /**
   * PATCH /api/sessions/{id} -> 200（P5 /title）。body {title}。
   *  网关代码实证存在（api_server.py 路由 + handler）；真实请求待 T2 补齐。
   *  改名不校验唯一性冲突（服务端 UNIQUE 约束：400 invalid_title 原样抛）。
   */
  async setTitle(sessionId: string, title: string): Promise<void> {
    let body: Record<string, string> = {};
    body['title'] = title;
    await this.client.request(http.RequestMethod.PATCH, '/api/sessions/' + sessionId, body);
  }

  /**
   * DELETE /api/sessions/{id} → {object,id,deleted}（网关硬删：行 + transcript + 渠道路由）。
   * 404 视为已删除（返回 false，不抛）；409 session_active_turn 原样上抛给调用方判定。
   */
  async deleteSession(sessionId: string): Promise<boolean> {
    try {
      let r: HttpResult = await this.client.request(
        http.RequestMethod.DELETE, '/api/sessions/' + sessionId, undefined);
      try {
        let d: Record<string, Object> = JSON.parse(r.body);
        return boolFrom(d['deleted']);
      } catch (err) {
        return r.code === 200;
      }
    } catch (err) {
      let e: ApiError = err as ApiError;
      if (e.code === 404) {
        return false;
      }
      throw e;
    }
  }
}
