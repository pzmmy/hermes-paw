// =====================================================================
// model/Profile.ets — 多服务器 profile（M1 设置页，方案 §4.1）
//
// P1-5/S1 跨 profile 语义：本地四元主键 = serverId + pf + role + sessionId，
// 跨网关 session_id 互不串号；serverId 取自 baseUrl 的 host:port。
// 网络三态（未配置/已配置/可达）与 MeshArc 引导见 §4.4（M0b）。
// =====================================================================

/** 网络类型：LAN=局域网直连；TAILNET=Tailscale 尾网（MeshArc） */
export enum NetworkKind {
  LAN = 'LAN',
  TAILNET = 'TAILNET'
}

export class ServerProfile {
  /** 本地唯一 ID（App 生成，跨启动稳定） */
  id: string = '';
  /** 显示名 */
  name: string = '';
  /** 网关地址 http://host:port（不带尾 /） */
  baseUrl: string = '';
  /** TokenVault 引用键（不存明文 token，§4.5 / P1-4） */
  tokenRef: string = '';
  /** 网络类型 */
  network: NetworkKind = NetworkKind.LAN;
  /** 服务端角色（X-Hermes-Session-Key）；M1 固定 default，M4 切角色 */
  role: string = 'default';
  /** UI 占位提示（P2-09：预设不预填真实地址，输入框展示格式提示） */
  placeholder: string = '';
  /** 是否预设（不可删，仅可重置） */
  isPreset: boolean = false;
  createdAt: number = 0;
  updatedAt: number = 0;
  /** profile prefix（S1，m2-qr-design）：扫码串 pf 参数；'' 或 'default'
   *  = 网关默认 scope（ApiClient 不加前缀）；其他值 -> 所有 path 加
   *  '/p/<pf>/'。与 role 正交：pf=URL scope，role=session-key header。 */
  pf: string = '';

  /** 四元主键组件：网关标识 = host:port（协议大小写不敏感，剥离 userinfo，P2-08） */
  get serverId(): string {
    let s: string = this.baseUrl;
    let lower: string = s.toLowerCase();
    if (lower.startsWith('https://')) {
      s = s.substring(8);
    } else if (lower.startsWith('http://')) {
      s = s.substring(7);
    }
    let at: number = s.indexOf('@');
    if (at >= 0) {
      s = s.substring(at + 1); // 剥离 userinfo
    }
    let slash: number = s.indexOf('/');
    if (slash >= 0) {
      s = s.substring(0, slash);
    }
    return s;
  }

  /** 地址是否已配置（三态指示：未配置/已配置/可达） */
  isConfigured(): boolean {
    return this.baseUrl !== '' && this.baseUrl.startsWith('http');
  }

  /**
   * Effective TokenVault key: explicit tokenRef when set, else the
   * profile id — keeps rows with an empty tokenRef (legacy or
   * hand-edited JSON) working; single fallback for all VM call
   * sites (batch2-r6 P1-r5-01).
   */
  vaultRef(): string {
    return this.tokenRef !== '' ? this.tokenRef : this.id;
  }
}

// 预设（Presets）已移除（v2.6.6，2026-11-16 主控拍板）：接入唯一路径 =
// 扫码/粘贴配置串（§4.8 提示词引导 + S1 三路径），不再提供手写预设。
// isPreset/placeholder 字段保留，仅服务 legacy 库行的只读渲染；
// NetworkKind.TAILNET 枚举同理保留。
