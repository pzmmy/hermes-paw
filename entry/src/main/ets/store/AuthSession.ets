// =====================================================================
// store/AuthSession.ets — 用户会话（token + email）持久化（P2）
//
// 存入 TokenVault（HUKS AES-256-GCM 信封）独立 ref 命名空间
// `sess:<serverId>/<pf>`，作用域到网关 profile（host:port + 前缀），
// 与网关按 profile 隔离的 account.db 对齐。信封为 JSON 包裹
// {t: token, e: email}——非密的 email 也留在加密块内，不落明文
// preferences。TokenVault 本体零改动（通用 ref 键控）。
// =====================================================================

import { common } from '@kit.AbilityKit';
import { LogSafe } from '../utils/LogSafe';
import { TokenVault } from './TokenVault';
import { ServerProfile } from '../model/Profile';
import { normPf } from '../model/LocalSession';

const TAG: string = 'AuthSession';

/** 登录身份，绑定到某个网关 profile（一个 profile 一个会话）。 */
export class AuthIdentity {
  token: string = '';
  email: string = '';
}

/** 用户会话的 TokenVault ref（作用域：host:port + 规范化前缀）。 */
export function sessionRefFor(profile: ServerProfile): string {
  let pf: string = normPf(profile.pf);
  let pfPart: string = pf !== '' ? pf : 'default';
  return 'sess:' + profile.serverId + '/' + pfPart;
}

/** 加密存入身份（同 ref 覆盖旧信封）。 */
export async function saveAuthIdentity(
  ctx: common.Context,
  profile: ServerProfile,
  identity: AuthIdentity
): Promise<void> {
  let payload: Record<string, string> = {};
  payload['t'] = identity.token;
  payload['e'] = identity.email;
  await TokenVault.saveToken(ctx, sessionRefFor(profile), JSON.stringify(payload));
  LogSafe.i(TAG, 'identity stored ref=%{public}s', sessionRefFor(profile));
}

/** 读取身份；无存储/无令牌 → null。信封损坏或 HUKS 失败 → 抛
 *  （调用方按"无会话"处理并走登录）。 */
export async function loadAuthIdentity(
  ctx: common.Context,
  profile: ServerProfile
): Promise<AuthIdentity | null> {
  let raw: string = await TokenVault.loadToken(ctx, sessionRefFor(profile));
  if (raw === '') {
    return null;
  }
  let d: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
  let t: Object | null | undefined = d['t'];
  if (t === null || t === undefined || String(t) === '') {
    return null;
  }
  let id: AuthIdentity = new AuthIdentity();
  id.token = String(t);
  let e: Object | null | undefined = d['e'];
  id.email = (e === null || e === undefined) ? '' : String(e);
  return id;
}

/** 删除本地会话副本（登出/会话失效）。 */
export async function clearAuthIdentity(
  ctx: common.Context,
  profile: ServerProfile
): Promise<void> {
  await TokenVault.deleteToken(ctx, sessionRefFor(profile));
  LogSafe.i(TAG, 'identity cleared ref=%{public}s', sessionRefFor(profile));
}
