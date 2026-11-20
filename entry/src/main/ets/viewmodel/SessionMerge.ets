// =====================================================================
// viewmodel/SessionMerge.ets — S9a：Hermes 标题规则派生 + 本地/服务端会话合并
// EN: Hermes title-rule derivation + local/server session merge (pure functions, no state, no IO).
// 纯函数（无状态、无 IO），可直接单测。
// 规则来源 gateway/agent/title_generator.py::derive_title：
//   首个有意义行 → 空白折叠 → ≤48 字符按词边界切 → 补 '…'
// =====================================================================

import { Msg } from '../utils/Msg';
import { LocalSession } from '../model/LocalSession';
import { SessionInfo } from '../net/SessionsApi';

export const LOCAL_TITLE_MAX_CHARS: number = 48;

/** 首个非空行（去首尾空白）；无可命名内容时返回 ''。 */
export function firstMeaningfulLine(text: string): string {
  if (text === '') {
    return '';
  }
  let lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let l: string = lines[i].trim();
    if (l !== '') {
      return l;
    }
  }
  return '';
}

/** 空白折叠（空格/制表/回车统一成单空格），不做正则。 */
function collapseSpaces(s: string): string {
  let out: string = '';
  let prevSpace: boolean = false;
  for (let i = 0; i < s.length; i++) {
    let c: string = s.charAt(i);
    let isSpace: boolean = (c === ' ' || c === '\t' || c === '\r');
    if (isSpace) {
      if (!prevSpace && out.length > 0) {
        out = out + ' ';
      }
      prevSpace = true;
    } else {
      out = out + c;
      prevSpace = false;
    }
  }
  return out;
}

/** 去掉尾部空白与句读符号（与服务端 derive_title 一致）。 */
function trimTitleTail(s: string): string {
  let out: string = s;
  while (out.length > 0) {
    let last: string = out.charAt(out.length - 1);
    if (last === ' ' || last === ',' || last === '.' || last === ';' || last === ':'
      || last === '—' || last === '-') {
      out = out.substring(0, out.length - 1);
    } else {
      break;
    }
  }
  return out;
}

/** Hermes derive_title 的客户端复刻（离线兜底，不调模型）。 */
export function deriveLocalTitle(text: string): string {
  let line: string = collapseSpaces(firstMeaningfulLine(text)).trim();
  if (line === '') {
    return '';
  }
  if (line.length <= LOCAL_TITLE_MAX_CHARS) {
    return line;
  }
  let cut: string = line.substring(0, LOCAL_TITLE_MAX_CHARS);
  let sp: number = cut.lastIndexOf(' ');
  let base: string = (sp > LOCAL_TITLE_MAX_CHARS / 2) ? cut.substring(0, sp) : cut;
  return trimTitleTail(base) + '…';
}

/** 合并后的一行；isLocal 决定列表左侧标签（本地 / 服务端）。 */
export class MergedSession {
  key: string = '';
  sessionId: string = '';
  title: string = '';
  isLocal: boolean = false;
  pk: string = '';
  lastActiveMs: number = 0;
  messageCount: number = 0;
  preview: string = '';
}

function indexOfId(list: MergedSession[], id: string): number {
  for (let i = 0; i < list.length; i++) {
    if (list[i].sessionId === id) {
      return i;
    }
  }
  return -1;
}

function toMs(v: number): number {
  if (v <= 0) {
    return 0;
  }
  return v > 100000000000 ? v : v * 1000;
}

/**
 * 同 sessionId 只出现一次：本地行优先（带 pk，可直接打开），
 * 服务端补权威标题（可能已被 llm 升级）、活跃时间与条数。
 */
export function mergeSessions(local: LocalSession[], server: SessionInfo[]): MergedSession[] {
  let out: MergedSession[] = [];
  for (let i = 0; i < local.length; i++) {
    let s: LocalSession = local[i];
    let m: MergedSession = new MergedSession();
    m.key = 'L|' + s.pk;
    m.sessionId = s.sessionId;
    m.title = s.title;
    m.isLocal = true;
    m.pk = s.pk;
    m.lastActiveMs = s.updatedAt;
    out.push(m);
  }
  for (let j = 0; j < server.length; j++) {
    let info: SessionInfo = server[j];
    let idx: number = indexOfId(out, info.id);
    let serverMs: number = toMs(info.last_active);
    if (idx >= 0) {
      let hit: MergedSession = out[idx];
      if (info.title !== '') {
        hit.title = info.title;
      }
      hit.messageCount = info.message_count;
      hit.preview = info.preview;
      if (serverMs > hit.lastActiveMs) {
        hit.lastActiveMs = serverMs;
      }
    } else {
      let m2: MergedSession = new MergedSession();
      m2.key = 'S|' + info.id;
      m2.sessionId = info.id;
      m2.title = info.title;
      m2.isLocal = false;
      m2.pk = '';
      m2.lastActiveMs = serverMs;
      m2.messageCount = info.message_count;
      m2.preview = info.preview;
      out.push(m2);
    }
  }
  for (let k: number = 0; k < out.length; k++) {
    out[k].title = fallbackTitle(out[k].title, out[k].sessionId);
  }
  out.sort((a: MergedSession, b: MergedSession): number => b.lastActiveMs - a.lastActiveMs);
  return out;
}

/** 本地行在服务端列表里找不到同 id 的统计（用于诊断「本地 · 0 条」）。 */
export class MatchReport {
  unmatched: number = 0;
  firstId: string = '';
}

export function unmatchedReport(local: LocalSession[], server: SessionInfo[]): MatchReport {
  let rep: MatchReport = new MatchReport();
  for (let i: number = 0; i < local.length; i++) {
    let sid: string = local[i].sessionId;
    let hit: boolean = false;
    for (let j: number = 0; j < server.length; j++) {
      if (server[j].id === sid) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      rep.unmatched = rep.unmatched + 1;
      if (rep.firstId === '') {
        rep.firstId = sid;
      }
    }
  }
  return rep;
}

/** 需要回写的标题变更（本地行已有真实标题且与服务端不同才产出）。 */
export class TitleUpdate {
  pk: string = '';
  title: string = '';
}

export function planTitleSync(local: LocalSession[], server: SessionInfo[]): TitleUpdate[] {
  let out: TitleUpdate[] = [];
  for (let i: number = 0; i < local.length; i++) {
    let ls: LocalSession = local[i];
    for (let j: number = 0; j < server.length; j++) {
      let info: SessionInfo = server[j];
      if (info.id !== ls.sessionId || info.title === '' || info.title === ls.title) {
        continue;
      }
      let u: TitleUpdate = new TitleUpdate();
      u.pk = ls.pk;
      u.title = info.title;
      out.push(u);
      break;
    }
  }
  return out;
}

/** 空标题兜底：'' -> '未命名 · <id 后 6 位>'，避免列表出现空白行。 */
export function fallbackTitle(title: string, sessionId: string): string {
  let t: string = title === undefined || title === null ? '' : title.trim();
  if (t !== '') {
    return t;
  }
  let id: string = sessionId === undefined || sessionId === null ? '' : sessionId;
  let n: number = id.length;
  let tail: string = n > 6 ? id.substring(n - 6) : id;
  return Msg.t('m_session_untitled_prefix') + tail;
}
