// =====================================================================
// store/DbHelper.ets — local persistence (SQLite via relationalStore,
// M1, plan section 4.5)
//
// Tables: sessions / messages / settings
// Composite pk (S1, P1-5): pk = serverId|pf|role|sessionId
//   (v1 3-tuple rows migrate in place, see migrateV1toV2)
// SecurityLevel S1; DB file: hermes_paw.db
// =====================================================================
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { LocalMessage } from '../model/ChatMessage';
import { LocalSession } from '../model/LocalSession';

const TAG: string = 'DbHelper';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'hermes_paw.db',
  securityLevel: relationalStore.SecurityLevel.S1
};

/** schema version: 2 = S1 (sessions.pf column, 4-tuple pk). */
const DB_VERSION: string = '2';
/** settings key holding the applied schema version (informational;
 *  the SELECT probe in sessionsHasPfColumn is authoritative). */
const KEY_DB_VERSION: string = 'db_version';

const SQL_CREATE_SESSIONS: string = 'CREATE TABLE IF NOT EXISTS sessions (' +
  'pk TEXT PRIMARY KEY, ' +
  'server_id TEXT NOT NULL, ' +
  'pf TEXT NOT NULL DEFAULT \'\', ' +
  'role TEXT NOT NULL, ' +
  'session_id TEXT NOT NULL, ' +
  'title TEXT NOT NULL DEFAULT \'\', ' +
  'created_at INTEGER NOT NULL, ' +
  'updated_at INTEGER NOT NULL)';

const SQL_CREATE_MESSAGES: string = 'CREATE TABLE IF NOT EXISTS messages (' +
  'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
  'session_pk TEXT NOT NULL, ' +
  'session_id TEXT NOT NULL DEFAULT \'\', ' +
  'server_msg_id INTEGER NOT NULL, ' +
  'role TEXT NOT NULL, ' +
  'content TEXT NOT NULL, ' +
  'truncated INTEGER NOT NULL DEFAULT 0, ' +
  'rev INTEGER NOT NULL DEFAULT 1, ' +
  'created_at INTEGER NOT NULL)';

const SQL_CREATE_IDX_MSG_SERVER: string = 'CREATE UNIQUE INDEX IF NOT EXISTS idx_msg_server ON messages ' +
  '(session_pk, server_msg_id) WHERE server_msg_id > 0';

const SQL_CREATE_IDX_MSG_PK: string = 'CREATE INDEX IF NOT EXISTS idx_msg_pk ON messages ' +
  '(session_pk, created_at)';

const SQL_CREATE_IDX_SESS_SR: string = 'CREATE INDEX IF NOT EXISTS idx_sess_sr ON sessions ' +
  '(server_id, role, updated_at)';

const SQL_CREATE_SETTINGS: string = 'CREATE TABLE IF NOT EXISTS settings (' +
  'key TEXT PRIMARY KEY, ' +
  'value TEXT NOT NULL)';

const SESSION_COLUMNS: string[] = [
  'pk', 'server_id', 'pf', 'role', 'session_id', 'title', 'created_at', 'updated_at'
];

const MESSAGE_COLUMNS: string[] = [
  'id', 'session_pk', 'session_id', 'server_msg_id', 'role',
  'content', 'truncated', 'rev', 'created_at'
];

/** Local persistence facade over relationalStore. */
export class DbHelper {
  private store: relationalStore.RdbStore | null = null;
  private static inst: DbHelper | null = null;
  /** In-flight init promise: concurrent get()/init() calls share one
   *  open attempt instead of racing on getRdbStore (batch2 P1-07). */
  private initP: Promise<void> | null = null;

  static async get(context: common.Context): Promise<DbHelper> {
    let inst: DbHelper | null = DbHelper.inst;
    if (inst === null) {
      inst = new DbHelper();
      DbHelper.inst = inst;
    }
    await inst.init(context);
    return inst;
  }

  /** Open (or reuse) the store and create schema; idempotent and safe
   *  to call from several coroutines at once (batch2 P1-07). */
  async init(context: common.Context): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initP === null) {
      this.initP = this.doInit(context);
    }
    return this.initP;
  }

  private async doInit(context: common.Context): Promise<void> {
    try {
      let store: relationalStore.RdbStore =
        await relationalStore.getRdbStore(context, STORE_CONFIG);
      await store.executeSql(SQL_CREATE_SESSIONS);
      await store.executeSql(SQL_CREATE_MESSAGES);
      await store.executeSql(SQL_CREATE_IDX_MSG_SERVER);
      await store.executeSql(SQL_CREATE_IDX_MSG_PK);
      await store.executeSql(SQL_CREATE_IDX_SESS_SR);
      await store.executeSql(SQL_CREATE_SETTINGS);
      // Migration runs after the settings table exists (db_version is
      // stored there) and before any caller sees the store.
      await this.migrateIfNeeded(store);
      this.store = store;
      LogSafe.d(TAG, 'rdb store ready');
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      // Allow a later get()/init() to retry after a failed init.
      this.initP = null;
      LogSafe.w(TAG, 'init failed: %{public}d', e.code);
      throw new Error('db: init failed');
    }
  }

  /**
   * Schema migration (S1, D3): v1 (no pf column, 3-tuple pk) -> v2
   * (pf column, 4-tuple pk). In-place: rows are kept, pk becomes
   * serverId|''|role|sessionId, messages.session_pk synced row by row.
   * Fresh installs land directly on v2 (probe sees pf, skips).
   */
  private async migrateIfNeeded(store: relationalStore.RdbStore): Promise<void> {
    if (await this.sessionsHasPfColumn(store)) {
      await this.writeDbVersion(store);
      return;
    }
    await this.migrateV1toV2(store);
    await this.writeDbVersion(store);
    LogSafe.i(TAG, 'migrated sessions v1 -> v2 (4-tuple pk)');
  }

  /** True when the sessions table has the pf column (v2 shape).
   *  Plain SELECT probe: the v1 shape rejects it ("no such column"). */
  private async sessionsHasPfColumn(store: relationalStore.RdbStore): Promise<boolean> {
    // No bind params: the empty literal is contextually typed by
    // querySql's SqlQueryParams (avoids naming the Blob type, which has
    // no stable import path across SDK versions).
    try {
      let rs: relationalStore.ResultSet =
        await store.querySql('SELECT pf FROM sessions LIMIT 1', []);
      rs.close();
      return true;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.i(TAG, 'pf probe failed: code=%{public}d (v1 shape)', e.code);
      return false;
    }
  }

  /** Write db_version directly on the store (this.store is not set
   *  yet during init, so putSetting would throw). */
  private async writeDbVersion(store: relationalStore.RdbStore): Promise<void> {
    let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('settings');
    preds.equalTo('key', KEY_DB_VERSION);
    let rs: relationalStore.ResultSet = await store.query(preds, ['value']);
    let exists: boolean = rs.goToNextRow();
    rs.close();
    let bucket: relationalStore.ValuesBucket = {};
    bucket['key'] = KEY_DB_VERSION;
    bucket['value'] = DB_VERSION;
    if (exists) {
      await store.update(bucket, preds);
    } else {
      await store.insert('settings', bucket);
    }
  }

  private async migrateV1toV2(store: relationalStore.RdbStore): Promise<void> {
    store.beginTransaction();
    try {
      // 1+2. rename the v1 table; create the v2 table (pf column)
      await store.executeSql('ALTER TABLE sessions RENAME TO sessions_v1');
      await store.executeSql(SQL_CREATE_SESSIONS);
      // 3. copy rows: new pk = serverId|''|role|sessionId (pf backfilled '')
      await store.executeSql(
        "INSERT INTO sessions (pk, server_id, pf, role, session_id, title, " +
        "created_at, updated_at) SELECT server_id || '|' || '|' || role || " +
        "'|' || session_id, server_id, '', role, session_id, title, " +
        "created_at, updated_at FROM sessions_v1");
      // 4. sync messages.session_pk row by row (portable; session
      //    counts are small by design, plan §4.5). Old (2-pipe) and
      //    new (3-pipe) pk shapes can never collide mid-loop.
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('sessions_v1');
      let rs: relationalStore.ResultSet =
        await store.query(preds, ['pk', 'server_id', 'role', 'session_id']);
      let oldPks: string[] = [];
      let newPks: string[] = [];
      try {
        while (rs.goToNextRow()) {
          oldPks.push(rs.getString(0));
          newPks.push(rs.getString(1) + '||' + rs.getString(2) + '|' + rs.getString(3));
        }
      } finally {
        rs.close();
      }
      for (let i: number = 0; i < oldPks.length; i++) {
        let msgPreds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
        msgPreds.equalTo('session_pk', oldPks[i]);
        let bucket: relationalStore.ValuesBucket = {};
        bucket['session_pk'] = newPks[i];
        await store.update(bucket, msgPreds);
      }
      // 5. drop v1 (its renamed index goes with it); recreate the
      //    session index on the fresh v2 table
      await store.executeSql('DROP TABLE sessions_v1');
      await store.executeSql(SQL_CREATE_IDX_SESS_SR);
      store.commit();
    } catch (err) {
      this.safeRollback(store);
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'migrateV1toV2 failed: %{public}d', e.code);
      throw new Error('db: migration v1->v2 failed');
    }
  }

  /** Read one session row (column order = SESSION_COLUMNS, v2 shape). */
  private readSessionRow(rs: relationalStore.ResultSet): LocalSession {
    let s: LocalSession = new LocalSession();
    s.pk = rs.getString(0);
    s.serverId = rs.getString(1);
    s.pf = rs.getString(2);
    s.role = rs.getString(3);
    s.sessionId = rs.getString(4);
    s.title = rs.getString(5);
    s.createdAt = rs.getLong(6);
    s.updatedAt = rs.getLong(7);
    return s;
  }

  private requireStore(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('db: not initialized');
    }
    return this.store;
  }

  /** API 12 RdbStore transaction rollback is named rollBack(). */
  private safeRollback(store: relationalStore.RdbStore): void {
    try {
      store.rollBack();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'rollback failed: %{public}d', e.code);
    }
  }

  // --- settings ---

  async putSetting(key: string, value: string): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let current: string = await this.getSetting(key);
      if (current === '') {
        let bucket: relationalStore.ValuesBucket = {};
        bucket['key'] = key;
        bucket['value'] = value;
        await store.insert('settings', bucket);
      } else {
        let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('settings');
        preds.equalTo('key', key);
        let bucket: relationalStore.ValuesBucket = {};
        bucket['value'] = value;
        await store.update(bucket, preds);
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'putSetting failed: %{public}d', e.code);
      throw new Error('db: putSetting failed');
    }
  }

  async getSetting(key: string): Promise<string> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('settings');
      preds.equalTo('key', key);
      let rs: relationalStore.ResultSet = await store.query(preds, ['value']);
      try {
        if (rs.goToNextRow()) {
          return rs.getString(0);
        }
        return '';
      } finally {
        rs.close();
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'getSetting failed: %{public}d', e.code);
      throw new Error('db: getSetting failed');
    }
  }

  /** Remove a settings row (no-op when absent). Clearing
   *  active_profile_id uses this instead of writing '': an empty value
   *  would break a second putSetting insert (batch2 P2-05 / r3 P0-C). */
  async deleteSetting(key: string): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('settings');
      preds.equalTo('key', key);
      await store.delete(preds);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'deleteSetting failed: %{public}d', e.code);
      throw new Error('db: deleteSetting failed');
    }
  }

  // --- sessions ---

  async upsertSession(s: LocalSession): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let existing: LocalSession | null = await this.getSession(s.pk);
      let now: number = Date.now();
      let createdAt: number = (s.createdAt === 0) ? now : s.createdAt;
      let updatedAt: number = (s.updatedAt === 0) ? now : s.updatedAt;
      if (existing === null) {
        let bucket: relationalStore.ValuesBucket = {};
        bucket['pk'] = s.pk;
        bucket['server_id'] = s.serverId;
        bucket['pf'] = s.pf;
        bucket['role'] = s.role;
        bucket['session_id'] = s.sessionId;
        bucket['title'] = s.title;
        bucket['created_at'] = createdAt;
        bucket['updated_at'] = updatedAt;
        await store.insert('sessions', bucket);
      } else {
        let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('sessions');
        preds.equalTo('pk', s.pk);
        let bucket: relationalStore.ValuesBucket = {};
        bucket['title'] = s.title;
        bucket['updated_at'] = updatedAt;
        bucket['session_id'] = s.sessionId;
        await store.update(bucket, preds);
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'upsertSession failed: %{public}d', e.code);
      throw new Error('db: upsertSession failed');
    }
  }

  async listSessions(serverId: string, pf: string, role: string): Promise<LocalSession[]> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('sessions');
      preds.equalTo('server_id', serverId);
      preds.equalTo('pf', pf);
      preds.equalTo('role', role);
      preds.orderByDesc('updated_at');
      let rs: relationalStore.ResultSet = await store.query(preds, SESSION_COLUMNS);
      let out: LocalSession[] = [];
      try {
        while (rs.goToNextRow()) {
          out.push(this.readSessionRow(rs));
        }
      } finally {
        rs.close();
      }
      return out;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'listSessions failed: %{public}d', e.code);
      throw new Error('db: listSessions failed');
    }
  }

  async getSession(pk: string): Promise<LocalSession | null> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('sessions');
      preds.equalTo('pk', pk);
      let rs: relationalStore.ResultSet = await store.query(preds, SESSION_COLUMNS);
      let out: LocalSession | null = null;
      try {
        if (rs.goToNextRow()) {
          out = this.readSessionRow(rs);
        }
      } finally {
        rs.close();
      }
      return out;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'getSession failed: %{public}d', e.code);
      throw new Error('db: getSession failed');
    }
  }

  async deleteSession(pk: string): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      store.beginTransaction();
      let sessionPreds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('sessions');
      sessionPreds.equalTo('pk', pk);
      await store.delete(sessionPreds);
      let messagePreds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
      messagePreds.equalTo('session_pk', pk);
      await store.delete(messagePreds);
      store.commit();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      this.safeRollback(store);
      LogSafe.w(TAG, 'deleteSession failed: %{public}d', e.code);
      throw new Error('db: deleteSession failed');
    }
  }

  async pruneSessions(serverId: string, pf: string, role: string,
                      keepCount: number, maxAgeMs: number): Promise<number> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('sessions');
      preds.equalTo('server_id', serverId);
      preds.equalTo('pf', pf);
      preds.equalTo('role', role);
      preds.orderByDesc('updated_at');
      let rs: relationalStore.ResultSet = await store.query(preds, ['pk', 'updated_at']);
      let toDelete: string[] = [];
      let cutoff: number = Date.now() - maxAgeMs;
      let index: number = 0;
      try {
        while (rs.goToNextRow()) {
          let pk: string = rs.getString(0);
          let updatedAt: number = rs.getLong(1);
          if (index >= keepCount || updatedAt < cutoff) {
            toDelete.push(pk);
          }
          index++;
        }
      } finally {
        rs.close();
      }
      for (let i: number = 0; i < toDelete.length; i++) {
        await this.deleteSession(toDelete[i]);
      }
      return toDelete.length;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'pruneSessions failed: %{public}d', e.code);
      throw new Error('db: pruneSessions failed');
    }
  }

  // --- messages ---

  private buildMessageBucket(msg: LocalMessage, content: string, truncatedFlag: number,
                             createdAt: number, rev: number): relationalStore.ValuesBucket {
    let bucket: relationalStore.ValuesBucket = {};
    bucket['session_pk'] = msg.key;
    bucket['session_id'] = msg.sessionId;
    bucket['server_msg_id'] = msg.serverMsgId;
    bucket['role'] = msg.role;
    bucket['content'] = content;
    bucket['truncated'] = truncatedFlag;
    bucket['rev'] = rev;
    bucket['created_at'] = createdAt;
    return bucket;
  }

  async saveMessages(msgs: LocalMessage[]): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      store.beginTransaction();
      for (let i: number = 0; i < msgs.length; i++) {
        let msg: LocalMessage = msgs[i];
        let content: string = msg.content;
        let truncatedFlag: number = 0;
        if (content.length > 2048) {
          content = content.substring(0, 2048) + '\n...[truncated]';
          truncatedFlag = 1;
        }
        let createdAt: number = (msg.createdAt === 0) ? Date.now() : msg.createdAt;
        if (msg.serverMsgId > 0) {
          let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
          preds.equalTo('session_pk', msg.key);
          preds.equalTo('server_msg_id', msg.serverMsgId);
          let rs: relationalStore.ResultSet = await store.query(preds, ['rev']);
          let found: boolean = false;
          let oldRev: number = 0;
          try {
            if (rs.goToNextRow()) {
              found = true;
              oldRev = rs.getLong(0);
            }
          } finally {
            rs.close();
          }
          if (found) {
            // The messages schema has no timestamp column; created_at is insert-only.
            let bucket: relationalStore.ValuesBucket = {};
            bucket['content'] = content;
            bucket['truncated'] = truncatedFlag;
            bucket['rev'] = oldRev + 1;
            await store.update(bucket, preds);
          } else {
            await store.insert('messages',
              this.buildMessageBucket(msg, content, truncatedFlag, createdAt, 1));
          }
        } else {
          await store.insert('messages',
            this.buildMessageBucket(msg, content, truncatedFlag, createdAt, 1));
        }
      }
      store.commit();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      this.safeRollback(store);
      LogSafe.w(TAG, 'saveMessages failed: %{public}d', e.code);
      throw new Error('db: saveMessages failed');
    }
  }

  async loadMessages(sessionPk: string): Promise<LocalMessage[]> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
      preds.equalTo('session_pk', sessionPk);
      preds.orderByAsc('created_at');
      let rs: relationalStore.ResultSet = await store.query(preds, MESSAGE_COLUMNS);
      let out: LocalMessage[] = [];
      try {
        while (rs.goToNextRow()) {
          let m: LocalMessage = new LocalMessage();
          m.id = rs.getLong(0);
          m.key = rs.getString(1);
          m.sessionId = rs.getString(2);
          m.serverMsgId = rs.getLong(3);
          m.role = rs.getString(4);
          m.content = rs.getString(5);
          m.truncated = (rs.getLong(6) !== 0);
          m.createdAt = rs.getLong(8);
          out.push(m);
        }
      } finally {
        rs.close();
      }
      return out;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'loadMessages failed: %{public}d', e.code);
      throw new Error('db: loadMessages failed');
    }
  }

  async countMessages(sessionPk: string): Promise<number> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
      preds.equalTo('session_pk', sessionPk);
      let rs: relationalStore.ResultSet = await store.query(preds, ['COUNT(*)']);
      let count: number = 0;
      try {
        if (rs.goToNextRow()) {
          count = rs.getLong(0);
        }
      } finally {
        rs.close();
      }
      return count;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'countMessages failed: %{public}d', e.code);
      throw new Error('db: countMessages failed');
    }
  }

  async deleteMessages(sessionPk: string): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
      preds.equalTo('session_pk', sessionPk);
      await store.delete(preds);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'deleteMessages failed: %{public}d', e.code);
      throw new Error('db: deleteMessages failed');
    }
  }

  async deleteMessage(id: number): Promise<void> {
    let store: relationalStore.RdbStore = this.requireStore();
    try {
      let preds: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('messages');
      preds.equalTo('id', id);
      await store.delete(preds);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'deleteMessage failed: %{public}d', e.code);
      throw new Error('db: deleteMessage failed');
    }
  }
}
