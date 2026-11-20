// =====================================================================
// viewmodel/SettingsVM.ets — server profile management (v2.6.6:
// QR-scan only — manual address/token entry removed, D3 superseded).
//
// Storage: settings table key 'profiles' = JSON array of plain profile
// objects; key 'active_profile_id' = string. Tokens live ONLY in
// TokenVault (HUKS AES-256-GCM), keyed by profile.vaultRef().
// QR imports use 'scan_<timestamp_ms>' (S1). Legacy 'preset_*' rows
// from pre-v2.6.6 builds remain readable and deletable (forward
// compatibility of the persisted JSON).
// =====================================================================
import { Msg } from '../utils/Msg';
import { http } from '@kit.NetworkKit';
import { common, bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { ApiClient, ApiError, HttpResult } from '../net/ApiClient';
import { describeApiError } from '../net/ErrorText';
import { DbHelper } from '../store/DbHelper';
import { TokenVault } from '../store/TokenVault';
import { ServerProfile, NetworkKind } from '../model/Profile';
import { SetupUri } from '../model/SetupUri';

const TAG: string = 'SettingsVM';

const PREF_PROFILES: string = 'profiles';
const PREF_ACTIVE: string = 'active_profile_id';

/** P3-01 修：诊断结果状态码。VM 只产出码 + 参数，Page 按码判色、按码选 i18n 键渲染。
 *  与 diag_* i18n 键一一对应（见 string.json）。 */
/** probeServer 的结构化产出：状态码 + 动态参数（供 Page 填 i18n 占位符）。 */
export interface DiagResult {
  status: number;
  params: Record<string, string>;
}

/** ArkTS 不支持 as const，用 class static readonly 表达状态码常量集。 */
export class DiagStatus {
  static readonly EMPTY: number = 0;            // 未诊断
  static readonly NOT_CONFIGURED: number = 1;   // diag_not_configured（红）
  static readonly BAD_URL: number = 2;          // diag_bad_url（红）
  static readonly NO_TOKEN: number = 3;         // diag_no_token（橙）
  static readonly AUTH_FAIL: number = 4;        // diag_auth_fail（红）
  static readonly OK: number = 5;               // diag_ok（绿）
  static readonly OK_CHECK_ERR: number = 6;     // diag_ok_check_err（绿）
  static readonly OK_CHECK_FAIL: number = 7;    // diag_ok_check_fail（绿）
  static readonly FAIL: number = 8;             // diag_fail（红）
  static readonly TOKEN_LOAD_FAIL: number = 9;  // diag_token_load_fail（红）
  static readonly BUSY: number = 10;            // diag_busy（灰，诊断中）
}

/** Option B 安全信息行：网关 Key 状态（只读展示，无账号节）。 */
export class KeyState {
  static readonly NONE: number = 0;        // 无激活档案（security_key_none）
  static readonly OPEN: number = 1;        // 免鉴权网关，无 Key（security_key_open，batch2-r7）
  static readonly CONFIGURED: number = 2;  // Key 已配置（security_key_configured/verified）
}

/** Option B 关于区：hermes-agent 版本拉取状态（/health 无鉴权探针）。 */
export class GwVersionState {
  static readonly FAIL: number = 0;    // 未提供
  static readonly LOADING: number = 1; // 获取中
  static readonly OK: number = 2;      // 拉取成功
}

/** Settings view model: scan-imported profile list + row actions. */
export class SettingsVM {
  // ---- reactive state ----
  profiles: ServerProfile[] = [];
  activeId: string = '';
  busy: boolean = false;
  error: string = '';
  notice: string = '';

  /** Row-level one-tap diagnose (non-IT users): which saved row is
   *  probing (diagId), whether a probe is in flight (diagBusy), and
   *  the result text mirrored under the row (diagText). */
  diagId: string = '';
  diagBusy: boolean = false;
  /** P3-01 修：诊断状态码（DiagStatus 常量）。Page 按它判色 + 用 $r() 渲染 i18n 文案，
   *  不再依赖中文串 startsWith 匹配。diagText 保留作旧值兼容（Page 已不读它判色）。 */
  diagStatus: number = DiagStatus.EMPTY;
  /** 状态对应的动态参数（code/ms/http/msg），Page 填入 i18n 占位符。 */
  diagParams: Record<string, string> = {};
  diagText: string = '';

  /** Option B (D6) 关于/安全信息区只读数据（loadAbout() 填充，Page 只渲染）。
   *  keyState=NONE → 无激活档案；OPEN = 免鉴权网关（batch2-r7，无 Key 合法）；
   *  gwVersionState=FAIL 或 gwVersion 空 → Page 显示「未提供」。 */
  appVersion: string = '';
  buildCode: string = '';
  activeUrl: string = '';
  keyState: number = KeyState.NONE;
  /** 验证标记：激活档案诊断结果为 OK 族时置 true；loadAbout() 重置 false。 */
  keyVerified: boolean = false;
  gwVersion: string = '';
  gwVersionState: number = GwVersionState.FAIL;

  /** BUG (settings list stuck "暂无"): @State vm on a plain (non-@Observed)
   *  class only tracks the reference, not this.profiles — so after load()
   *  fills the array the page never re-renders the list. The page injects a
   *  callback that bumps its @State version counter; profiles/error/notice
   *  mutations call notifyUi(). Same pattern as ChatVM.onUiChange. */
  onUiChange: () => void;

  /** Fire the page re-render hook (sync, VM's own context). */
  private notifyUi(): void {
    this.onUiChange();
  }

  private ctx: common.Context;
  private db: DbHelper;

  constructor(ctx: common.Context, db: DbHelper) {
    this.ctx = ctx;
    this.db = db;
    // ArkTS rejects an inline arrow-function initializer on a function-typed
    // field; default to a no-op, the page overwrites it after creation.
    this.onUiChange = (): void => {};
  }

  /** 供 SettingsPage 直接读写非 profile 类配置项（如恢复轮询间隔）。
   *  返回 DbHelper 实例，调用方负责 putSetting/getSetting。 */
  getDb(): DbHelper {
    return this.db;
  }

  /** Load profiles and the active id from the settings table. */
  async load(): Promise<void> {
    this.error = '';
    this.notice = '';
    let json: string = '';
    try {
      json = await this.db.getSetting(PREF_PROFILES);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'load profiles failed: code=%{public}d message=%{public}s',
        e.code, String(e.message));
      this.error = Msg.t('m_settings_read_config_fail');
      return;
    }
    this.profiles = parseProfilesJson(json);
    try {
      this.activeId = await this.db.getSetting(PREF_ACTIVE);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'load active profile failed: code=%{public}d message=%{public}s',
        e.code, String(e.message));
      this.error = Msg.t('m_settings_read_current_fail');
      return;
    }
    LogSafe.d(TAG, 'profiles loaded (%{public}d)', this.profiles.length);
    // Self-heal a dangling active_profile_id: the row points to a
    // profile that no longer exists (legacy state from before the
    // batch2-r3 P0-C delete-on-reset). Clear it in memory, drop row.
    if (this.activeId !== '' && this.profileForId(this.activeId) === null) {
      LogSafe.w(TAG, 'stale active_profile_id cleared');
      this.activeId = '';
      try {
        await this.db.deleteSetting(PREF_ACTIVE);
      } catch (err) {
        // best-effort: in-memory state is already corrected
      }
    }
    this.notifyUi();
  }

  /**
   * Import a QR setup URI (S1, D4): new profile 'scan_<ts>' with the
   * chosen host, key into TokenVault, activated. Each scan adds a row
   * (stale rows are deletable from the list). The profile list is
   * re-read from the DB first so a cold VM never persists a partial
   * array over existing rows.
   */
  async importSetup(su: SetupUri, host: string): Promise<boolean> {
    if (this.busy) {
      this.error = Msg.t('m_settings_busy');
      return false;
    }
    this.busy = true;
    this.error = '';
    this.notice = '';
    try {
      await this.load();
      if (this.error !== '') {
        return false; // DB read failed: do not persist a partial list
      }
      let now: number = Date.now();
      let p: ServerProfile = new ServerProfile();
      p.id = 'scan_' + String(now);
      p.name = su.name;
      p.baseUrl = 'http://' + host;
      p.tokenRef = p.id;
      p.network = NetworkKind.LAN;
      p.role = 'default';
      p.pf = su.pf;
      p.isPreset = false;
      p.placeholder = '';
      p.createdAt = now;
      p.updatedAt = now;
      await TokenVault.saveToken(this.ctx, p.vaultRef(), su.key);
      let arr: ServerProfile[] = this.profiles.slice();
      arr.push(p);
      this.profiles = arr;
      await this.persist();
      await this.db.putSetting(PREF_ACTIVE, p.id);
      this.activeId = p.id;
      this.notice = Msg.t('m_scan_imported') + p.name;
      this.notifyUi();
      return true;
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'importSetup failed: %{public}s', e.message);
      this.error = Msg.t('m_settings_import_fail') + e.message;
      return false;
    } finally {
      this.busy = false;
    }
  }

  /**
   * Two-stage probe (v2.6.4; sole probe path after v2.6.6 removed the
   * manual form + its test button):
   *   1) GET /health (open, no auth) — server reachability
   *   2) if a token is available (the stored token of the row):
   *      GET /v1/models with Bearer — the data plane is auth-required
   *      (measured 2026-10-29: /health 200 without key, /v1/models
   *      401), so a health-only probe used to report a false
   *      "connected" for non-IT users.
   *   3) no token at all: reachable, but say so explicitly — messages
   *      will 401 until a QR with a valid token is scanned again.
   * Non-throwing by design: every branch returns one plain-Chinese,
   * non-IT-user-readable result line with elapsed ms. The models body
   * stays in the debug log only (truncated to 80 chars), never in
   * user-facing text.
   */
  /** ArkTS 对象字面量需显式类型，用 helper 构造 DiagResult。 */
  private mkDiag(status: number, params: Record<string, string>): DiagResult {
    let r: DiagResult = { status: status, params: params };
    return r;
  }

  private diagParamsOf(pairs: string[]): Record<string, string> {
    let rec: Record<string, string> = {};
    for (let i: number = 0; i < pairs.length; i += 2) {
      rec[pairs[i]] = pairs[i + 1];
    }
    return rec;
  }

  /** P3-01 修：返回结构化诊断结果（状态码 + 动态参数），文案 i18n 交给 Page 渲染。 */
  private async probeServer(url: string, token: string, pf: string, role: string): Promise<DiagResult> {
    if (url === '') {
      return this.mkDiag(DiagStatus.NOT_CONFIGURED, this.diagParamsOf([]));
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return this.mkDiag(DiagStatus.BAD_URL, this.diagParamsOf([]));
    }
    let t0: number = Date.now();
    let c: ApiClient = new ApiClient();
    c.configure(url, token, role, pf);
    try {
      let r: HttpResult = await c.request(
        http.RequestMethod.GET, '/health', undefined, 8000, true);
      if (token === '') {
        LogSafe.w(TAG, 'probe: reachable, no token configured');
        return this.mkDiag(DiagStatus.NO_TOKEN, this.diagParamsOf(['ms', String(Date.now() - t0)]));
      }
      try {
        let m: HttpResult = await c.request(
          http.RequestMethod.GET, '/v1/models', undefined, 8000, true);
        let brief: string = m.body.length > 80 ? m.body.substring(0, 80) : m.body;
        LogSafe.d(TAG, 'probe ok: health %{public}d models %{public}d %{public}s',
          r.code, m.code, brief);
        return this.mkDiag(DiagStatus.OK,
          this.diagParamsOf(['code', String(r.code), 'ms', String(Date.now() - t0)]));
      } catch (err2) {
        if (err2 instanceof ApiError) {
          let e2: ApiError = err2 as ApiError;
          if (e2.code === 401) {
            LogSafe.w(TAG, 'probe: 401 on /v1/models (bad token)');
            return this.mkDiag(DiagStatus.AUTH_FAIL, this.diagParamsOf([]));
          }
          LogSafe.w(TAG, 'probe: models check HTTP %{public}d', e2.code);
          return this.mkDiag(DiagStatus.OK_CHECK_ERR,
            this.diagParamsOf(['code', String(r.code), 'http', String(e2.code)]));
        }
        let e2: Error = err2 as Error;
        LogSafe.w(TAG, 'probe: models check failed: %{public}s', e2.message);
        return this.mkDiag(DiagStatus.OK_CHECK_FAIL,
          this.diagParamsOf(['code', String(r.code), 'msg', e2.message]));
      }
    } catch (err) {
      let ms: string = String(Date.now() - t0);
      if (err instanceof ApiError) {
        let e: ApiError = err as ApiError;
        LogSafe.w(TAG, 'probe failed: %{public}s', e.message);
        return this.mkDiag(DiagStatus.FAIL, this.diagParamsOf(['msg', describeApiError(e), 'ms', ms]));
      }
      let e: Error = err as Error;
      LogSafe.w(TAG, 'probe failed: %{public}s', e.message);
      return this.mkDiag(DiagStatus.FAIL, this.diagParamsOf(['msg', e.message, 'ms', ms]));
    }
  }

  /** Option B (D6) 关于/安全信息区只读数据装配：
   *  1) App 版本/构建号（bundleManager，与 ScanVM 同源）；
   *  2) 激活档案网关地址 + Key 状态（batch2-r7：无 Key = 免鉴权，合法态）；
   *  3) 无鉴权 /health 拉 hermes-agent 版本（兼容探针同源，失败降级「未提供」）。
   *  任一段失败只降级该段，绝不 reject。 */
  async loadAbout(): Promise<void> {
    try {
      let info: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appVersion = info.versionName;
      this.buildCode = String(info.versionCode);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'loadAbout: bundle info failed: %{public}s', e.message);
    }
    let p: ServerProfile | null = this.getActiveProfile();
    this.keyVerified = false;
    if (p === null) {
      this.activeUrl = '';
      this.keyState = KeyState.NONE;
      this.gwVersion = '';
      this.gwVersionState = GwVersionState.FAIL;
      this.notifyUi();
      return;
    }
    this.activeUrl = p.baseUrl;
    let hasToken: boolean = true;
    try {
      let tok: string = await TokenVault.loadToken(this.ctx, p.vaultRef());
      hasToken = tok !== '';
    } catch (err) {
      // HUKS 读取失败时保守显示「已配置」，避免误导用户重新扫码。
      LogSafe.w(TAG, 'loadAbout: token load failed (showing configured)');
    }
    this.keyState = hasToken ? KeyState.CONFIGURED : KeyState.OPEN;
    if (p.baseUrl !== '') {
      this.gwVersionState = GwVersionState.LOADING;
      this.notifyUi();
      let t0: number = Date.now();
      try {
        let c: ApiClient = new ApiClient();
        c.configure(p.baseUrl, '', p.role, p.pf);
        let r: HttpResult = await c.request(
          http.RequestMethod.GET, '/health', undefined, 6000, true);
        if (r.code === 200) {
          let o: Record<string, Object> = JSON.parse(r.body) as Record<string, Object>;
          let v: Object | undefined = o['version'];
          let vs: string = v === undefined ? '' : String(v);
          this.gwVersion = vs;
          this.gwVersionState = vs !== '' ? GwVersionState.OK : GwVersionState.FAIL;
        } else {
          this.gwVersionState = GwVersionState.FAIL;
        }
      } catch (err) {
        let e: Error = err as Error;
        LogSafe.w(TAG, 'loadAbout: /health failed: %{public}s', e.message);
        this.gwVersionState = GwVersionState.FAIL;
      }
      LogSafe.d(TAG, 'loadAbout: gw version=%{public}s (%{public}d ms)',
        this.gwVersion, Date.now() - t0);
    } else {
      this.gwVersionState = GwVersionState.FAIL;
    }
    this.notifyUi();
  }

  /**
   * One-tap diagnose for a saved row (non-IT users): probe the row's
   * stored address + HUKS vault token; the result is mirrored under the
   * row (diagId/diagText). Zero side effect on any other state.
   * Mutual exclusion: ignored while a QR import (busy) or another row
   * diagnose (diagBusy) is in flight. finally guarantees diagBusy
   * resets even on an unexpected rejection (no stuck "诊断中…" button).
   */
  async diagnoseProfile(id: string): Promise<void> {
    if (this.busy || this.diagBusy) {
      return;
    }
    let p: ServerProfile | null = this.profileForId(id);
    if (p === null) {
      return;
    }
    this.diagId = p.id;
    this.diagBusy = true;
    this.diagStatus = DiagStatus.BUSY;
    this.diagParams = {};
    this.diagText = Msg.t('m_settings_diagnosing');
    try {
      let token: string = '';
      try {
        token = await TokenVault.loadToken(this.ctx, p.vaultRef());
      } catch (err) {
        let e: Error = err as Error;
        LogSafe.w(TAG, 'diagnose: token load failed: %{public}s', e.message);
        this.diagStatus = DiagStatus.TOKEN_LOAD_FAIL;
        this.diagParams = { 'msg': e.message };
        this.diagText = Msg.t('m_settings_read_token_fail') + e.message;
        return;
      }
      let res: DiagResult = await this.probeServer(p.baseUrl, token, p.pf, p.role);
      this.diagStatus = res.status;
      this.diagParams = res.params;
    } finally {
      this.diagBusy = false;
      // Option B 安全信息行：诊断完成即刷新激活档案的 Key 验证标记。
      if (this.diagId === this.activeId) {
        let st: number = this.diagStatus;
        this.keyVerified = (st === DiagStatus.OK || st === DiagStatus.OK_CHECK_ERR ||
          st === DiagStatus.OK_CHECK_FAIL);
      }
    }
  }

  /**
   * Set the active profile (must be configured; token optional —
   * gateways may run unauthenticated, batch2-r7).
   * Returns true when the switch happened, so the page can notify the
   * chat screen to re-initialize (batch2 P0-C).
   */
  async setActive(id: string): Promise<boolean> {
    if (this.busy) {
      this.error = Msg.t('m_settings_busy');
      return false;
    }
    this.error = '';
    this.notice = '';
    let p: ServerProfile | null = this.profileForId(id);
    if (p === null) {
      this.error = Msg.t('m_settings_server_missing');
      return false;
    }
    if (!p.isConfigured()) {
      this.error = Msg.t('m_settings_server_no_addr');
      return false;
    }
    // No token gate (batch2-r7): unauthenticated gateways are valid;
    // a wrong/missing token surfaces as 401 on the data plane.
    try {
      await this.db.putSetting(PREF_ACTIVE, id);
    } catch (err) {
      let e: Error = err as Error;
      this.error = Msg.t('m_settings_activate_fail') + e.message;
      return false;
    }
    this.activeId = id;
    // Replace the array reference so the ForEach re-diffs and the
    // "已激活" badge moves to the new row (batch2 P0-B).
    this.profiles = this.profiles.slice();
    this.notice = Msg.t('m_settings_activated') + p.name;
    return true;
  }

  /**
   * Delete a saved row + its vault token (v2.6.6: profiles are
   * scan-import-only, so delete is the sole row-level action — re-scan
   * to re-add). Legacy preset_* rows are handled the same way.
   * Returns true when the profile list changed, so the page can notify
   * the chat screen (batch2 P0-C).
   *
   * Reactivity: the rows go through a new array reference (batch2
   * P0-A/P0-B).
   */
  async resetProfile(id: string): Promise<boolean> {
    this.error = '';
    this.notice = '';
    let p: ServerProfile | null = this.profileForId(id);
    if (p === null) {
      return false;
    }
    let idx: number = this.indexOfProfile(id);
    if (idx >= 0) {
      let arr: ServerProfile[] = this.profiles.slice();
      arr.splice(idx, 1);
      this.profiles = arr;
    }
    try {
      await TokenVault.deleteToken(this.ctx, p.vaultRef());
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'delete token failed: code=%{public}d message=%{public}s',
        e.code, String(e.message));
    }
    if (this.activeId === id) {
      this.activeId = '';
      // Persist the cleared active id by DELETING the row (not by
      // writing '': an empty value breaks the second putSetting insert,
      // batch2-r2 P0-C). Best-effort: on failure a stale row remains,
      // which load() self-heals on next start.
      try {
        await this.db.deleteSetting(PREF_ACTIVE);
      } catch (err) {
        let e: Error = err as Error;
        LogSafe.w(TAG, 'clear active_profile_id failed: %{public}s', e.message);
      }
    }
    try {
      await this.persist();
    } catch (err) {
      let e: Error = err as Error;
      this.error = Msg.t('m_settings_save_fail') + e.message;
      return false;
    }
    this.notice = Msg.t('m_settings_deleted') + p.name;
    this.notifyUi();
    return true;
  }

  /** The active, configured profile (sync; call after load()). */
  getActiveProfile(): ServerProfile | null {
    if (this.activeId === '') {
      return null;
    }
    let p: ServerProfile | null = this.profileForId(this.activeId);
    if (p === null || !p.isConfigured()) {
      return null;
    }
    return p;
  }

  private async persist(): Promise<void> {
    let arr: Array<Record<string, Object>> = [];
    for (let i: number = 0; i < this.profiles.length; i++) {
      let p: ServerProfile = this.profiles[i];
      let o: Record<string, Object> = {};
      o['id'] = p.id;
      o['name'] = p.name;
      o['baseUrl'] = p.baseUrl;
      o['tokenRef'] = p.tokenRef;
      o['network'] = p.network;
      o['role'] = p.role;
      o['pf'] = p.pf;
      o['placeholder'] = p.placeholder;
      o['isPreset'] = p.isPreset;
      o['createdAt'] = p.createdAt;
      o['updatedAt'] = p.updatedAt;
      arr.push(o);
    }
    let json: string = JSON.stringify(arr);
    await this.db.putSetting(PREF_PROFILES, json);
  }

  private profileForId(id: string): ServerProfile | null {
    for (let i: number = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].id === id) {
        return this.profiles[i];
      }
    }
    return null;
  }

  private indexOfProfile(id: string): number {
    for (let i: number = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].id === id) {
        return i;
      }
    }
    return -1;
  }
}

/** Decode the settings JSON array into profiles; never throws. */
function parseProfilesJson(json: string): ServerProfile[] {
  let out: ServerProfile[] = [];
  if (json === '') {
    return out;
  }
  try {
    let raw: Object = JSON.parse(json);
    if (raw instanceof Array) {
      let arr: Array<Object> = raw as Array<Object>;
      for (let i: number = 0; i < arr.length; i++) {
        let o: Record<string, Object> = arr[i] as Record<string, Object>;
        let p: ServerProfile = new ServerProfile();
        p.id = strFrom(o['id']);
        p.name = strFrom(o['name']);
        p.baseUrl = strFrom(o['baseUrl']);
        p.tokenRef = strFrom(o['tokenRef']);
        p.network = o['network'] === 'TAILNET' ? NetworkKind.TAILNET : NetworkKind.LAN;
        p.role = strFrom(o['role']);
        if (p.role === '') {
          p.role = 'default';
        }
        p.pf = strFrom(o['pf']);
        p.placeholder = strFrom(o['placeholder']);
        p.isPreset = o['isPreset'] === true;
        p.createdAt = numFrom(o['createdAt']);
        p.updatedAt = numFrom(o['updatedAt']);
        if (p.id !== '') {
          out.push(p);
        }
      }
    }
  } catch (err) {
    let e: Error = err as Error;
    LogSafe.w(TAG, 'profiles parse failed: %{public}s', e.message);
  }
  return out;
}

/** JSON Object -> string (null/undefined safe). */
function strFrom(v: Object | null | undefined): string {
  if (v === null || v === undefined) {
    return '';
  }
  return String(v);
}

/** JSON Object -> number (NaN/missing -> 0). */
function numFrom(v: Object | null | undefined): number {
  if (v === null || v === undefined) {
    return 0;
  }
  let n: number = Number(v);
  return Number.isNaN(n) ? 0 : n;
}
