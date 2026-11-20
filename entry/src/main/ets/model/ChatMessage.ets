// =====================================================================
// model/ChatMessage.ets — 聊天消息（本地模型 + 服务端形状）
//
// 服务端消息形状（S-01 实证，GET /api/sessions/{id}/messages）：
//   {data: [{id, role, content, session_id, timestamp, finish_reason,
//            reasoning, reasoning_content, tool_calls, tool_name,
//            tool_call_id, display_kind, token_count}]}
// 字段类型：selftest 仅断言数量 ≥2，未断言字段类型 → 此处宽松解析（P2-03）
// 本地存储策略（§4.5）：只存可渲染内容，超长截断并置 truncated 标记。
// =====================================================================

import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';

const TAG: string = 'ChatMessage';

export enum MessageRole {
  USER = 'user',
  ASSISTANT = 'assistant',
  SYSTEM = 'system',
  TOOL = 'tool'
}

/** 服务端消息条目（/api/sessions/{id}/messages data[] 子集；id/timestamp 宽松解析，selftest 未断言类型） */
export interface ServerMessage {
  id: number;
  role: string;
  content: string;
  session_id: string;
  timestamp: number;
  finish_reason: string;
  tool_name: string;
}

/** 本地 SQLite 消息行（§4.5；三元主键由 DbHelper 拼装：serverId+role+sessionId） */
export class LocalMessage {
  id: number = 0;
  key: string = '';
  sessionId: string = '';
  role: string = MessageRole.USER;
  content: string = '';
  /** 对应服务端消息 id（对齐/对账用） */
  serverMsgId: number = 0;
  /** S2-a: album picker uris attached to this user message (transient,
   *  in-memory only — the server stages its own copies and the local
   *  schema is unchanged; refetched rows carry no thumbnails). */
  imageUris: string[] = [];
  /** BUG-001: the model's reasoning/thinking preamble, split out of the
   *  assistant output so it can render in a collapsible block instead of
   *  polluting the reply bubble. Transient (in-memory only, like
   *  imageUris) — the SQLite schema is unchanged. Empty for user rows and
   *  for replies with no detectable preamble. */
  thinking: string = '';
  timestamp: number = 0;
  truncated: boolean = false;
  createdAt: number = 0;
  /** 本轮收口耗时（ms）。-1 = 未知（历史消息 / 非本轮），UI 不显示。
   *  仅内存字段，刻意不落库（不改 DbHelper 的 SQL / 表结构）。 */
  elapsedMs: number = -1;
  /** 首帧增量耗时（ms）。-1 = 全程无增量（只能终态整段上屏）。仅内存。 */
  firstDeltaMs: number = -1;
}

/** 宽容解析 /api/sessions/{id}/messages 响应 */
export function parseServerMessages(body: string): ServerMessage[] {
  let out: ServerMessage[] = [];
  try {
    let d: Record<string, Object> = JSON.parse(body);
    let arrObj: Object | null | undefined = d['data'];
    if (arrObj === null || arrObj === undefined) {
      arrObj = d['messages'];
    }
    if (arrObj === null || arrObj === undefined || !(arrObj instanceof Array)) {
      return out;
    }
    let arr: Record<string, Object>[] = arrObj as Record<string, Object>[];
    for (let i = 0; i < arr.length; i++) {
      let m: Record<string, Object> = arr[i];
      let idRaw: Object | null | undefined = m['id'];
      if (idRaw === null || idRaw === undefined) {
        LogSafe.w(TAG, 'server message id missing (selftest unasserted, lenient)');
      }
      let sm: ServerMessage = {
        id: numFrom(m['id']),
        role: strFrom(m['role']),
        content: strFrom(m['content']),
        session_id: strFrom(m['session_id']),
        timestamp: numFrom(m['timestamp']),
        finish_reason: strFrom(m['finish_reason']),
        tool_name: strFrom(m['tool_name'])
      };
      out.push(sm);
    }
  } catch (err) {
    let e: BusinessError = err as BusinessError;
    LogSafe.w(TAG, 'messages parse failed, lenient: %{public}s', String(e.message));
  }
  return out;
}

/**
 * BUG-001: split an assistant output into (thinking, replyBody).
 *
 * The gateway's run.completed `output` concatenates the model's reasoning
 * preamble and the final reply, separated by one or more blank lines
 * (evidence-verified 2026-11-16: `\n\n\n` between the two). We take the
 * LAST blank-line boundary: everything before it is the preamble
 * (thinking / tool-result text), everything after is the reply shown in
 * the bubble.
 *
 * Heuristic trade-offs (deliberate, low-risk):
 *  - A multi-paragraph reply with a `\n\n\n` inside would split its tail
 *    into the preamble — but the preamble renders in a collapsible block,
 *    so no content is lost; the user can expand it.
 *  - A single-paragraph reply (no double blank line) returns ('', full),
 *    i.e. untouched.
 *
 * Returns both empty-free; '' for the part that is absent.
 */
export function splitThinking(output: string): string[] {
  let trimmed: string = output.trim();
  if (trimmed === '') {
    return ['', ''];
  }
  let idx: number = trimmed.lastIndexOf('\n\n\n');
  if (idx < 0) {
    idx = trimmed.lastIndexOf('\n\n');
  }
  if (idx <= 0) {
    return ['', trimmed];
  }
  let thinking: string = trimmed.substring(0, idx).trim();
  let body: string = trimmed.substring(idx).trim();
  if (thinking === '' || body === '') {
    return ['', trimmed];
  }
  return [thinking, body];
}

/** JSON 取值辅助：Object -> string（null/undefined 安全） */
export function strFrom(v: Object | null | undefined): string {
  if (v === null || v === undefined) {
    return '';
  }
  return String(v);
}

/** JSON 取值辅助：Object -> number（NaN/缺省取 0） */
export function numFrom(v: Object | null | undefined): number {
  if (v === null || v === undefined) {
    return 0;
  }
  let n: number = Number(v);
  return isNaN(n) ? 0 : n;
}
