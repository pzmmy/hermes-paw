// =====================================================================
// viewmodel/LoginVM.ets — 登录流（P2）：邮箱 + 6 位验证码
//
// 状态机：idle →（发码）→ sent（60s 重发倒计时）→（校验）→
// 成功（会话令牌入 TokenVault）| 失败（白话文案 + 下一步动作）。
// D1 UX：错误一律白话 + 下一步，绝不裸抛 401/码。
// 错误文案与 ChatVM 同层惯例：VM 层中文硬编码（i18n 缺口由 P3
// 设置页统一处理）。
// =====================================================================

import { Msg } from '../utils/Msg';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { ApiClient, ApiError } from '../net/ApiClient';
import { AuthApi, authErrorCode } from '../net/AuthApi';
import { TokenVault } from '../store/TokenVault';
import { ServerProfile } from '../model/Profile';
import { AuthIdentity, loadAuthIdentity, saveAuthIdentity } from '../store/AuthSession';

const TAG: string = 'LoginVM';
const COUNTDOWN_SECONDS: number = 60;

/** 白话化描述 auth API 失败（D1 UX）。先具体网关码，再网络级，最后通用。 */
export function describeAuthError(e: Error): string {
  if (e instanceof ApiError) {
    let ae: ApiError = e;
    let code: string = authErrorCode(ae);
    if (code === 'invalid_code') {
      return Msg.t('m_login_bad_code');
    }
    if (code === 'rate_limited') {
      return Msg.t('m_login_too_frequent');
    }
    if (code === 'smtp_unavailable') {
      return Msg.t('m_login_send_code_fail');
    }
    if (code === 'invalid_email') {
      return Msg.t('m_login_bad_email');
    }
    let c: number = ae.code;
    if (c === 0 || c === -1 || (c >= 2300000 && c < 2400000)) {
      return Msg.t('m_login_unreachable');
    }
    return Msg.t('m_login_req_fail');
  }
  return Msg.t('m_login_req_fail');
}

/** 与网关同级的宽松邮箱预检（网关仍是最终裁决者，doc §6）。 */
function isValidEmail(v: string): boolean {
  if (v.length < 5 || v.length > 254) {
    return false;
  }
  let at: number = v.indexOf('@');
  if (at <= 0 || at === v.length - 1) {
    return false;
  }
  if (v.indexOf('@', at + 1) !== -1) {
    return false;
  }
  let dot: number = v.lastIndexOf('.');
  return dot > at + 1 && dot < v.length - 1;
}

export class LoginVM {
  email: string = '';
  code: string = '';
  sending: boolean = false;
  verifying: boolean = false;
  /** 重发倒计时（秒）；0 = 可发。 */
  countdownSec: number = 0;
  error: string = '';
  /** 副标题用的网关标识（host:port）。 */
  serverLabel: string = '';
  onUiChange: () => void;

  private ctx: common.Context;
  private profile: ServerProfile;
  private client: ApiClient;
  private auth: AuthApi;
  private countdownId: number = -1;
  private disposed: boolean = false;

  constructor(ctx: common.Context, profile: ServerProfile) {
    this.ctx = ctx;
    this.profile = profile;
    this.client = new ApiClient();
    this.auth = new AuthApi(this.client);
    this.serverLabel = profile.serverId;
    // BUG-005 fix2 同款：钩子默认 no-op，页面创建 VM 后立即覆写。
    this.onUiChange = (): void => {};
  }

  /** 装载网关密钥（可能为空 → 无鉴权网关）并预填上次登录的邮箱。 */
  async init(): Promise<void> {
    let token: string = '';
    try {
      token = await TokenVault.loadToken(this.ctx, this.profile.vaultRef());
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'gateway key load failed: code=%{public}d', e.code);
    }
    this.client.configure(this.profile.baseUrl, token, this.profile.role, this.profile.pf);
    try {
      let id: AuthIdentity | null = await loadAuthIdentity(this.ctx, this.profile);
      if (id !== null && id.email !== '') {
        this.email = id.email;
      }
    } catch (err) {
      // 陈旧/损坏信封：无邮箱可预填，登录流本身不受影响。
      LogSafe.w(TAG, 'identity prefill skipped: %{public}s', (err as Error).message);
    }
    this.notifyUi();
  }

  private notifyUi(): void {
    this.onUiChange();
  }

  /** 验证码输入过滤：仅数字、至多 6 位（onChange 返回过滤后值）。 */
  onCodeInput(v: string): string {
    let out: string = '';
    for (let i = 0; i < v.length && out.length < 6; i++) {
      let ch: string = v.substring(i, i + 1);
      if (ch >= '0' && ch <= '9') {
        out = out + ch;
      }
    }
    return out;
  }

  private startCountdown(): void {
    this.stopCountdown();
    this.countdownSec = COUNTDOWN_SECONDS;
    this.notifyUi();
    let step: () => void = (): void => {
      if (this.disposed) {
        return;
      }
      if (this.countdownSec > 1) {
        this.countdownSec = this.countdownSec - 1;
        this.notifyUi();
        this.countdownId = setTimeout(step, 1000);
      } else {
        this.countdownSec = 0;
        this.countdownId = -1;
        this.notifyUi();
      }
    };
    this.countdownId = setTimeout(step, 1000);
  }

  private stopCountdown(): void {
    if (this.countdownId !== -1) {
      clearTimeout(this.countdownId);
      this.countdownId = -1;
    }
  }

  /** 停止倒计时（页面 aboutToDisappear 调用）。 */
  destroy(): void {
    this.disposed = true;
    this.stopCountdown();
  }

  /** POST /api/auth/request-code → 启动 60s 重发倒计时。 */
  async sendCode(): Promise<void> {
    if (this.sending || this.verifying) {
      return;
    }
    this.error = '';
    let email: string = this.email.trim();
    if (!isValidEmail(email)) {
      this.error = Msg.t('m_login_bad_email');
      this.notifyUi();
      return;
    }
    this.email = email;
    this.sending = true;
    this.notifyUi();
    try {
      await this.auth.requestCode(email);
      this.startCountdown();
    } catch (err) {
      this.error = describeAuthError(err as Error);
    } finally {
      this.sending = false;
      this.notifyUi();
    }
  }

  /** POST /api/auth/verify → 会话令牌入 TokenVault，报告成功。
   *  返回 true = 登录成功（页面应返回并触发 profile 变更）。 */
  async login(): Promise<boolean> {
    if (this.sending || this.verifying) {
      return false;
    }
    this.error = '';
    let email: string = this.email.trim();
    let code: string = this.code.trim();
    if (!isValidEmail(email)) {
      this.error = Msg.t('m_login_bad_email');
      this.notifyUi();
      return false;
    }
    if (code.length !== 6) {
      this.error = Msg.t('m_login_need_code');
      this.notifyUi();
      return false;
    }
    this.verifying = true;
    this.notifyUi();
    try {
      let token: string = await this.auth.verify(email, code);
      let id: AuthIdentity = new AuthIdentity();
      id.token = token;
      id.email = email;
      await saveAuthIdentity(this.ctx, this.profile, id);
      this.stopCountdown();
      this.code = '';
      LogSafe.i(TAG, 'login ok');
      return true;
    } catch (err) {
      this.error = describeAuthError(err as Error);
      return false;
    } finally {
      this.verifying = false;
      this.notifyUi();
    }
  }
}
