// =====================================================================
// viewmodel/session/SessionStore.ets — S9c：会话读写与管理（从 ChatVM 外移）
// EN: Session read/write turned into its own class (extracted from ChatVM); data side only — run state stays in ChatVM.
// 只做数据侧：读本地/服务端列表、标题回写、合并视图、删除、接手建行。
// run 状态（messages/streamText/busy/审批）仍留在 ChatVM，本类不碰。
// =====================================================================

import { Msg } from '../../utils/Msg';
import { SessionsApi, SessionInfo } from '../../net/SessionsApi';
import { LocalSession, buildLocalPk } from '../../model/LocalSession';
import { DbHelper } from '../../store/DbHelper';
import { LogSafe } from '../../utils/LogSafe';
import { ApiError } from '../../net/ApiClient';
import { describeError } from '../../net/ErrorText';
import { ServerProfile } from '../../model/Profile';
import { MergedSession, mergeSessions, unmatchedReport, planTitleSync, TitleUpdate } from '../SessionMerge';

const TAG: string = 'SessionStore';
const RETENTION_MAX_SESSIONS: number = 200;
const RETENTION_MAX_AGE_MS: number = 90 * 24 * 60 * 60 * 1000;

/** 标题回写结果：changed=是否有行被写；activeTitle=当前会话的新标题（无则空串）。 */
export class TitleSync {
  changed: boolean = false;
  activeTitle: string = '';
}

/** 删除结果：ok=false 时 message 为给用户看的文案。 */
export class DeleteOutcome {
  ok: boolean = false;
  message: string = '';
  authExpired: boolean = false;
}

export class SessionStore {
  private db: DbHelper;
  private api: SessionsApi;
  private profile: ServerProfile;

  constructor(db: DbHelper, api: SessionsApi, profile: ServerProfile) {
    this.db = db;
    this.api = api;
    this.profile = profile;
  }

  /** 本地会话列表（updated_at desc），顺带 fire-and-forget 清理超限行。 */
  async listLocal(): Promise<LocalSession[]> {
    let rows: LocalSession[] = await this.db.listSessions(
      this.profile.serverId, this.profile.pf, this.profile.role);
    this.db.pruneSessions(this.profile.serverId, this.profile.pf, this.profile.role,
      RETENTION_MAX_SESSIONS, RETENTION_MAX_AGE_MS)
      .catch((err: Error): void => {
        LogSafe.w(TAG, 'pruneSessions failed: %{public}s', err.message);
      });
    return rows;
  }

  /** 服务端会话列表（调用方负责 401/会话失效的 UI 处理）。 */
  async listServer(): Promise<SessionInfo[]> {
    return await this.api.listSessions();
  }

  /** 把服务端权威标题回写到本地行；返回是否有变更与当前会话新标题。 */
  async applyServerTitles(server: SessionInfo[], activePk: string): Promise<TitleSync> {
    let out: TitleSync = new TitleSync();
    let locals: LocalSession[] = await this.db.listSessions(
      this.profile.serverId, this.profile.pf, this.profile.role);
    let updates: TitleUpdate[] = planTitleSync(locals, server);
    for (let i: number = 0; i < updates.length; i++) {
      let u: TitleUpdate = updates[i];
      for (let j: number = 0; j < locals.length; j++) {
        if (locals[j].pk !== u.pk) {
          continue;
        }
        locals[j].title = u.title;
        locals[j].updatedAt = Date.now();
        await this.db.upsertSession(locals[j]);
        out.changed = true;
        if (activePk !== '' && activePk === locals[j].pk) {
          out.activeTitle = u.title;
        }
        break;
      }
    }
    return out;
  }

  /** 合并视图（UI 只渲染这个）。顺带打诊断：本地行在服务端找不到同 id 的数量。 */
  merged(local: LocalSession[], server: SessionInfo[]): MergedSession[] {
    let rows: MergedSession[] = mergeSessions(local, server);
    let rep = unmatchedReport(local, server);
    LogSafe.d(TAG, 'merged: local=%{public}d server=%{public}d unmatched=%{public}d first=%{public}s',
      local.length, server.length, rep.unmatched, rep.firstId);
    return rows;
  }

  /** 删除会话：先删服务端（404 视为已删），再删本地行。busy 判定由调用方做。 */
  async remove(pk: string, sessionId: string): Promise<DeleteOutcome> {
    let out: DeleteOutcome = new DeleteOutcome();
    let sid: string = sessionId;
    if (pk !== '') {
      let s: LocalSession | null = null;
      try {
        s = await this.db.getSession(pk);
      } catch (err) {
        LogSafe.w(TAG, 'remove: read local failed: %{public}s', (err as Error).message);
        out.message = Msg.t('m_vm_read_local_fail');
        return out;
      }
      if (s === null) {
        return out;
      }
      sid = s.sessionId;
    }
    try {
      await this.api.deleteSession(sid);
    } catch (err) {
      let e: ApiError = err as ApiError;
      if (e.code === 409) {
        out.message = Msg.t('m_session_active_no_delete');
        return out;
      }
      if (e.code === 401 || e.code === 403) {
        out.authExpired = true;
        out.message = Msg.t('m_vm_login_expired');
        return out;
      }
      LogSafe.w(TAG, 'remove: server failed: %{public}d', e.code);
      out.message = Msg.t('m_session_delete_fail') + describeError(err as Error);
      return out;
    }
    if (pk !== '') {
      try {
        await this.db.deleteSession(pk);
      } catch (err) {
        LogSafe.w(TAG, 'remove: local failed: %{public}s', (err as Error).message);
      }
    }
    out.ok = true;
    return out;
  }

  /** 接手服务端会话：本机没有该行时先建（pk 确定），返回 pk 供 openSession。 */
  async ensureLocalRow(id: string, title: string): Promise<string> {
    let pk: string = buildLocalPk(this.profile.serverId, this.profile.pf, this.profile.role, id);
    let existing: LocalSession | null = await this.db.getSession(pk);
    if (existing !== null) {
      return pk;
    }
    let now: number = Date.now();
    let s: LocalSession = new LocalSession();
    s.serverId = this.profile.serverId;
    s.pf = this.profile.pf;
    s.role = this.profile.role;
    s.sessionId = id;
    s.pk = pk;
    s.title = title === '' ? Msg.t('m_chat_untitled_session') : title;
    s.createdAt = now;
    s.updatedAt = now;
    await this.db.upsertSession(s);
    return pk;
  }
}