// =====================================================================
// pages/SettingsPage.ets — server settings (v2.6.6: QR-scan only).
//
// Profiles are added/updated ONLY by scanning a QR (OnboardPage prompt
// flow, or ScanPage camera/album/paste). Manual IP/Token entry was
// removed (v2.6.6, 主控 decision — supersedes the old D3 fallback).
// Row-level actions: activate / diagnose / delete.
//
// Security note shown to the user: tokens are stored encrypted
// (HUKS AES-256-GCM) — plaintext never leaves the device, never
// enters the repository.
// =====================================================================
import { Msg } from '../utils/Msg';
import { common } from '@kit.AbilityKit';
import { LogSafe } from '../utils/LogSafe';
import { emitter } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { DbHelper } from '../store/DbHelper';
import { SettingsVM, DiagStatus } from '../viewmodel/SettingsVM';
import { ChatVM } from '../viewmodel/ChatVM';
import { JobsApi, JobInfo } from '../net/JobsApi';
import { ApiClient } from '../net/ApiClient';
import { TokenVault } from '../store/TokenVault';
import { loadAuthIdentity, clearAuthIdentity, AuthIdentity } from '../store/AuthSession';
import { ServerProfile, NetworkKind } from '../model/Profile';
import { PROFILE_CHANGED_EVENT_ID } from './ScanPage';
import { accentPrimary, accentTint, accentSavedIndex, accentSave, ACCENT_PRESETS, AccentPreset } from '../theme/Accent';

const TAG: string = 'SettingsPage';

// 2026-11-18：LICENSE_MIT 常量和 COPY_OPTION_LOCAL_DEVICE 常量已随「开源信息」
// 组移到 AboutPage.ets（SettingsPage 不再渲染只读信息区）。

@Component
export struct SettingsPage {
  @State vm: SettingsVM | null = null;
  @State bootError: string = '';
  /** Re-render tick for the row-level diagnose: the VM is a plain
   *  class, so diagText is pulled on the next build — bumping this
   *  @State forces that build. The value itself is never rendered. */
  @State diagTick: number = 0;
  /** BUG (settings list stuck "暂无"): @State vm can't observe
   *  SettingsVM.profiles (plain class, non-@Observed), so the list stayed
   *  empty even after load() populated it. Mirror the array into this @State
   *  field: assigning a NEW array reference after load() is what @State
   *  actually tracks, and it reliably re-renders the ForEach. vm is truth. */
  @State profileList: ServerProfile[] = [];
  /** Normalized app preferred language: 'default' | 'zh' | 'en'. Drives
   *  the checkmark; the framework applies the switch on cold start. */
  @State appLang: string = 'default';
  /** Saved accent index into ACCENT_PRESETS. Drives the swatch checkmark;
   *  the new accent applies on the next cold start. */
  @State accentIdx: number = 0;
  /** 恢复轮询基础间隔（秒），Slider 显示值。范围 1~60，默认 5。
   *  aboutToAppear 时从 DbHelper 读，onRecoverPollChange 保存。 */
  /** 本机是否存有当前网关的登录会话（决定「退出登录」是否显示）。
   *  aboutToAppear 里 svm.load() 之后读取；退出成功后置 false。 */
  @State hasSession: boolean = false;
  @State recoverPollSec: number = 5;
  /** Conduit 借鉴：定时任务列表（/api/jobs）。aboutToAppear 时加载。 */
  @State jobList: JobInfo[] = [];
  /** Invoked by Index whenever a profile is saved / activated / reset,
   *  so the chat screen can re-initialize (batch2 P0-C).
   *  Default no-op: ArkTS requires struct members to be initialized
   *  (batch2-r4 P0-03); Index overrides it via the component parameter. */
  onProfileChanged: () => void = (): void => {};

  aboutToAppear(): void {
    // A3: seed the language checkmark (merged from the former 更多 tab).
    try {
      let raw: string = i18n.System.getAppPreferredLanguage();
      this.appLang = this.normLang(raw);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'getAppPreferredLanguage failed: %{public}s', e.message);
    }

    // getContext deprecated since API 18; getHostContext is the official
    // replacement (batch2-r4 P1-01). UIAbility page: host context is UIAbilityContext.
    let ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // A3: seed the accent checkmark (persisted choice, applied on cold start).
    accentSavedIndex(ctx).then((i: number): void => {
      this.accentIdx = i;
    });
    DbHelper.get(ctx).then((db: DbHelper) => {
      let svm: SettingsVM = new SettingsVM(ctx, db);
      // BUG (settings list "暂无"): mirror vm.profiles into @State profileList.
      // @State tracks the array REFERENCE, so assigning a new slice after
      // load()/save/delete reliably re-renders the ForEach (vm itself is a
      // plain class whose fields @State vm cannot observe).
      let page: SettingsPage = this;
      svm.onUiChange = (): void => {
        page.profileList = svm.profiles.slice();
      };
      this.vm = svm;
      svm.load().then((): void => {
        page.profileList = svm.profiles.slice();
        // Option B 关于/安全信息区：档案加载完成后装配只读信息行（各段失败自降级，不 reject）。
        svm.loadAbout().catch((err2: Error): void => {
          LogSafe.w(TAG, 'loadAbout failed: %{public}s', err2.message);
        });
      }).catch((err: Error) => {
        // 留白-01 收口：启动错误文案走 i18n（占位符 %s = 错误消息）。
        try {
          this.bootError = ctx.resourceManager.getStringSync($r('app.string.load_failed_fmt'), err.message);
        } catch (e2) {
          this.bootError = Msg.t('m_settings_load_fail') + err.message;
        }
      });
      // 配置页：读恢复轮询间隔（秒），seed Slider 显示值。
      db.getSetting('recover_poll_interval_ms').then((raw: string): void => {
        if (raw !== '') {
          let ms: number = Number(raw);
          if (ms >= 1000 && ms <= 60000) {
            this.recoverPollSec = Math.round(ms / 1000);
          }
        }
      }).catch((err: Error): void => {
        LogSafe.w(TAG, 'read recover_poll_interval_ms failed: %{public}s', err.message);
      });

      // Conduit 借鉴：加载定时任务列表（/api/jobs）。在 svm.load() 之后
      // 用 active profile 的 ApiClient 请求；失败静默（老版本网关可能无此端点）。
      let page2: SettingsPage = this;
      svm.load().then((): void => {
        let active: ServerProfile | null = svm.getActiveProfile();
        if (active !== null && active.isConfigured()) {
          let prof: ServerProfile = active;
          // 退出登录的可见性：本机是否存有该 profile 的会话（读失败按「无」处理）。
          loadAuthIdentity(ctx, prof).then((id: AuthIdentity | null): void => {
            page2.hasSession = id !== null;
          }).catch((err: Error): void => {
            page2.hasSession = false;
            LogSafe.w(TAG, 'loadAuthIdentity failed: %{public}s', err.message);
          });
          let ac: ApiClient = new ApiClient();
          ac.configure(prof.baseUrl, '', prof.role, prof.pf);
          // token 从 TokenVault 异步加载（不阻塞 UI）
          TokenVault.hasToken(ctx, prof.vaultRef()).then((has: boolean): void => {
            if (has) {
              TokenVault.loadToken(ctx, prof.vaultRef()).then((tok: string): void => {
                ac.configure(prof.baseUrl, tok, prof.role, prof.pf);
                let ja: JobsApi = new JobsApi(ac);
                ja.listJobs().then((jobs: JobInfo[]): void => {
                  page2.jobList = jobs;
                }).catch((err: Error): void => {
                  LogSafe.w(TAG, 'listJobs failed: %{public}s', err.message);
                });
              }).catch((err: Error): void => {
                LogSafe.w(TAG, 'loadToken for jobs failed: %{public}s', err.message);
              });
            }
          }).catch((err: Error): void => {
            LogSafe.w(TAG, 'hasToken for jobs failed: %{public}s', err.message);
          });
        }
      }).catch((err: Error): void => {
        LogSafe.w(TAG, 'load for jobs failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      // 留白-01 收口：启动错误文案走 i18n（占位符 %s = 错误消息）。
      try {
        this.bootError = ctx.resourceManager.getStringSync($r('app.string.db_init_failed_fmt'), err.message);
      } catch (e2) {
        this.bootError = Msg.t('m_about_db_init_fail') + err.message;
      }
    });

    // S1: refresh the profile list when a QR import completes on
    // ScanPage. (Index bumps profileVer on the same event for the
    // chat tab — the list reload here is local to this page.)
    emitter.on({ eventId: PROFILE_CHANGED_EVENT_ID }, (): void => {
      let s: SettingsVM | null = this.vm;
      if (s !== null) {
        s.load().catch((err: Error): void => {
          LogSafe.w(TAG, 'reload after scan failed: %{public}s', err.message);
        });
      }
    });
  }

  aboutToDisappear(): void {
    emitter.off(PROFILE_CHANGED_EVENT_ID);
  }

  private v(): SettingsVM {
    return this.vm as SettingsVM;
  }

  /** Bump the profile version in Index so the chat screen re-syncs
   *  (batch2 P0-C). */
  private notifyProfileChanged(): void {
    this.onProfileChanged();
  }

  /** P3-01 修：按诊断状态码判色（不再中文串 startsWith 匹配）。
   *  绿=连接成功系（OK/OK_CHECK_ERR/OK_CHECK_FAIL）；橙=可达但缺 Token；
   *  灰=诊断中；红=其余（未配置/格式错/401/连接失败/读Token失败）。 */
  private diagColor(): string {
    let s: number = this.v().diagStatus;
    if (s === DiagStatus.OK || s === DiagStatus.OK_CHECK_ERR || s === DiagStatus.OK_CHECK_FAIL) {
      return '#2E7D32';
    }
    if (s === DiagStatus.NO_TOKEN) {
      return '#EF6C00';
    }
    if (s === DiagStatus.BUSY) {
      return '#757575';
    }
    return '#C62828';
  }

  /** 取 diagParams 某键值，缺省返回空串（ArkTS 禁 lambda 赋值，用方法）。 */
  private diagParam(p: Record<string, string>, k: string): string {
    let v: string | undefined = p[k];
    return v !== undefined ? v : '';
  }

  /** 留白-02 收口：状态码 → $r() i18n 基础句（无占位符键，与 string.json diag_* 一一对应）。
   *  声明式 $r() 跟随 app 首选语言（含热切换），替代旧 getStringSync 手动语言映射
   *  （旧法实测热切换后 locale 不跟随，仍取 base）。
   *  动态值（health HTTP 码/耗时）由 diagSuffixOf() 作通用后缀追加（跨语言不本地化）。 */
  private diagBaseRes(s: number): Resource {
    if (s === DiagStatus.NOT_CONFIGURED) {
      return $r('app.string.diag_not_configured');
    } else if (s === DiagStatus.BAD_URL) {
      return $r('app.string.diag_bad_url');
    } else if (s === DiagStatus.NO_TOKEN) {
      return $r('app.string.diag_no_token');
    } else if (s === DiagStatus.AUTH_FAIL) {
      return $r('app.string.diag_auth_fail');
    } else if (s === DiagStatus.OK) {
      return $r('app.string.diag_ok');
    } else if (s === DiagStatus.OK_CHECK_ERR) {
      return $r('app.string.diag_ok_check_err');
    } else if (s === DiagStatus.OK_CHECK_FAIL) {
      return $r('app.string.diag_ok_check_fail');
    } else if (s === DiagStatus.TOKEN_LOAD_FAIL) {
      return $r('app.string.diag_token_load_fail');
    } else if (s === DiagStatus.FAIL) {
      return $r('app.string.diag_fail');
    }
    // BUSY / EMPTY：探针在途（EMPTY 仅瞬态，diagnoseProfile 同步置 BUSY）。
    return $r('app.string.diag_busy');
  }

  /** 动态值后缀：health HTTP 码 + 耗时（通用，跨语言）。 */
  private diagSuffixOf(): string {
    let s: number = this.v().diagStatus;
    let p: Record<string, string> = this.v().diagParams;
    let suffix: string = '';
    let code: string = this.diagParam(p, 'code');
    let ms: string = this.diagParam(p, 'ms');
    if (code !== '') {
      suffix += ' · HTTP ' + code;
    }
    if (ms !== '') {
      suffix += ' · ' + ms + ' ms';
    }
    if (s === DiagStatus.FAIL && this.diagParam(p, 'msg') !== '') {
      suffix += ': ' + this.diagParam(p, 'msg');
    }
    return suffix;
  }

  private onGoScan(): void {
    router.pushUrl({ url: 'pages/ScanPage' }).catch((err: Error): void => {
      LogSafe.w(TAG, 'push ScanPage failed: %{public}s', err.message);
    });
  }

  private onGoOnboard(): void {
    router.pushUrl({ url: 'pages/OnboardPage' }).catch((err: Error): void => {
      LogSafe.w(TAG, 'push OnboardPage failed: %{public}s', err.message);
    });
  }

  /** Row-level one-tap diagnose: the VM sets its sync prefix
   *  ("诊断中…") before the first await, so the first tick already
   *  renders it; the completion/rejection tick renders the result. */
  private onDiagnose(id: string): void {
    let s: SettingsVM | null = this.vm;
    if (s === null) {
      return;
    }
    this.diagTick += 1;
    s.diagnoseProfile(id).then((): void => {
      this.diagTick += 1;
    }).catch((err: Error): void => {
      LogSafe.w(TAG, 'diagnose failed: %{public}s', err.message);
      this.diagTick += 1;
    });
  }

  /** 删除为破坏性操作：先确认再执行（v2.6.6 对话框易用性）。
   *  删除 = 档案行 + 其 HUKS 加密 Token；重新接入请再次扫码。 */
  private confirmDelete(id: string, name: string): void {

    this.getUIContext().showAlertDialog({
      title: $r('app.string.delete_dialog_title'),
      message: $r('app.string.delete_dialog_msg_fmt', name),
      buttons: [
        { value: $r('app.string.cancel'), fontColor: '#757575', action: (): void => {} },
        { value: $r('app.string.delete'), fontColor: '#E53935', action: (): void => {
          let s: SettingsVM = this.v();
          s.resetProfile(id).then((ok: boolean): void => {
            if (ok) {
              this.notifyProfileChanged();
            }
          });
        } }
      ]
    });
  }

  /** 退出登录：清除本机保存的网关会话（HUKS 加密块），随后通知 Index 抬升
   *  profileVer —— 聊天页重建 VM → connect() → /me 无有效会话 → 401 →
   *  authMode 翻成 'loggedOut' → 登录闸门接管整屏。
   *  不动档案本身（baseUrl/角色仍保留），只清会话：重新接入只需扫码/输入 Key。 */
  private confirmSignOut(): void {
    let s: SettingsVM | null = this.vm;
    if (s === null) {
      return;
    }
    let active: ServerProfile | null = s.getActiveProfile();
    if (active === null) {
      return;
    }
    let name: string = active.name !== '' ? active.name : active.baseUrl;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.signout_dialog_title'),
      message: $r('app.string.signout_dialog_msg_fmt', name),
      buttons: [
        { value: $r('app.string.cancel'), fontColor: '#757575', action: (): void => {} },
        { value: $r('app.string.settings_signout'), fontColor: '#E53935', action: (): void => {
          let ctx: common.UIAbilityContext =
            this.getUIContext().getHostContext() as common.UIAbilityContext;
          clearAuthIdentity(ctx, active).then((): void => {
            this.hasSession = false;
            LogSafe.i(TAG, 'signed out (identity cleared)');
            // 让聊天页重建 VM 并重新探测登录态（401 → 闸门）。
            this.notifyProfileChanged();
            // 页面内反馈：走 SettingsVM.notice（本页已有渲染位），
            // diagTick 自增强制重绘（VM 是普通类，@State 观察不到）。
            let svm: SettingsVM | null = this.vm;
            if (svm !== null) {
              svm.notice = Msg.t('signout_done');
              this.diagTick += 1;
            }
          }).catch((err: Error): void => {
            LogSafe.w(TAG, 'clearAuthIdentity failed: %{public}s', err.message);
          });
        } }
      ]
    });
  }

  /** Map an arbitrary preferred-language string onto the three UI
   *  options: zh* -> 'zh', en* -> 'en', anything else -> 'default'. */
  private normLang(raw: string): string {
    if (raw.startsWith('zh')) {
      return 'zh';
    }
    if (raw.startsWith('en')) {
      return 'en';
    }
    return 'default';
  }

  /** Apply the chosen language. setAppPreferredLanguage hot-swaps the
   *  resource bundle live (P3-02 实证：真机中↔英即时热更新生效)，无需重启。 */
  private onPickLang(code: string): void {
    try {
      i18n.System.setAppPreferredLanguage(code);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'setAppPreferredLanguage failed: %{public}s', e.message);
    }
    this.appLang = code;
  }

  /** Persist the chosen accent (cold-start apply, same semantics as the
   *  language switch). The checkmark updates immediately. */
  private onPickAccent(idx: number): void {
    this.accentIdx = idx;
    let ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    accentSave(ctx, idx);
  }

  /** 保存恢复轮询间隔（秒→ms 写入 DbHelper）。值即时生效（下次 recovery 读），
   *  无需重启 App。直接写 DbHelper（与 SettingsVM 无关，不触发 profile 刷新）。 */
  private onRecoverPollChange(sec: number): void {
    this.recoverPollSec = sec;
    let ms: number = sec * 1000;
    let s: SettingsVM | null = this.vm;
    if (s !== null) {
      s.getDb().putSetting('recover_poll_interval_ms', String(ms)).catch((err: Error): void => {
        LogSafe.w(TAG, 'save recover_poll_interval_ms failed: %{public}s', err.message);
      });
    }
  }

  // 2026-11-18：about 相关方法（aboutAppVersionText/aboutBuildText/aboutGwAddrText/
  // aboutGwVersionText/securityKeyText/securityKeyColor）已随「关于」组移到
  // AboutPage.ets。SettingsPage 不再渲染只读信息区。

  build() {
    Column() {
      if (this.vm === null) {
        Text(this.bootError !== '' ? this.bootError : $r('app.string.loading'))
          .fontSize(14)
      } else {
        Text($r('app.string.settings_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .padding(12)
          .alignSelf(ItemAlign.Start)

        if (this.v().error !== '') {
          Text(this.v().error)
            .fontSize(12)
            .fontColor($r('app.color.danger'))
            .padding({ left: 12, right: 12 })
            .width('100%')
        }

        if (this.v().notice !== '') {
          Text(this.v().notice)
            .fontSize(12)
            .fontColor(accentPrimary())
            .padding({ left: 12, right: 12 })
            .width('100%')
        }

        Scroll() {
          Column() {
            Button($r('app.string.settings_first_onboard'))
              .fontSize(13)
              .height(36)
              .type(ButtonType.Normal)
              .backgroundColor($r('app.color.success_soft'))
              .fontColor($r('app.color.success'))
              .borderRadius(8)
              .width('100%')
              .margin({ bottom: 8 })
              .onClick(() => {
                this.onGoOnboard();
              })

            Button($r('app.string.settings_scan'))
              .fontSize(13)
              .height(36)
              .type(ButtonType.Normal)
              .backgroundColor(accentTint())
              .fontColor(accentPrimary())
              .borderRadius(8)
              .width('100%')
              .margin({ bottom: 4 })
              .onClick(() => {
                this.onGoScan();
              })

            // ===== 第 2 组：通用（语言 + 强调色）=====
            Text($r('app.string.settings_group_general'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 16, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            // A3: language switch (merged from the former 更多 tab).
            Text($r('app.string.lang_section'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 12, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            Column() {
              Row() {
                Text($r('app.string.lang_follow_system'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                if (this.appLang === 'default') {
                  Text('✓').fontSize(16).fontColor($r('app.color.success'))
                }
              }
              .width('100%')
              .height(52)
              .onClick((): void => { this.onPickLang('default'); })

              Divider().strokeWidth(0.5).color($r('app.color.divider'))

              Row() {
                Text($r('app.string.lang_zh'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                if (this.appLang === 'zh') {
                  Text('✓').fontSize(16).fontColor($r('app.color.success'))
                }
              }
              .width('100%')
              .height(52)
              .onClick((): void => { this.onPickLang('zh'); })

              Divider().strokeWidth(0.5).color($r('app.color.divider'))

              Row() {
                Text($r('app.string.lang_en'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                if (this.appLang === 'en') {
                  Text('✓').fontSize(16).fontColor($r('app.color.success'))
                }
              }
              .width('100%')
              .height(52)
              .onClick((): void => { this.onPickLang('en'); })
            }
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(10)
            .padding({ left: 16, right: 16 })
            .width('100%')
            .margin({ bottom: 8 })

            // A3: accent picker (applies on next cold start, like language).
            Text($r('app.string.accent_section'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 4, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            Column() {
              Row() {
                ForEach(ACCENT_PRESETS, (preset: AccentPreset, idx: number) => {
                  Stack() {
                    Circle()
                      .width(30)
                      .height(30)
                      .fill(preset.primary)
                    if (this.accentIdx === idx) {
                      Text('✓')
                        .fontSize(14)
                        .fontColor($r('app.color.text_inverse'))
                    }
                  }
                  .margin({ left: 8, right: 8 })
                  .onClick((): void => {
                    this.onPickAccent(idx);
                  })
                }, (preset: AccentPreset) => preset.primary)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 4, bottom: 4 })
            }
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(10)
            .padding({ left: 16, right: 16 })
            .width('100%')
            .margin({ bottom: 16 })

            // ===== 第 3 组：高级（断流重试间隔 + 定时任务，技术向放最后）=====
            Text($r('app.string.settings_group_advanced'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 4, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            // 恢复轮询间隔（BUG-005 配置页可调）：Slider 1~60s，默认 5s。
            // 值变化即保存到 DbHelper（无需重启 App，下次 recovery 生效）。
            Text($r('app.string.recover_poll_section'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 4, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            Column() {
              Row() {
                Text($r('app.string.recover_poll_hint'))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                Blank()
                Text(this.recoverPollSec + 's')
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .margin({ bottom: 8 })

              Slider({
                value: this.recoverPollSec,
                min: 1,
                max: 60,
                step: 1
              })
                .blockSize({ width: 20, height: 20 })
                .trackThickness(4)
                .selectedColor(accentPrimary())
                .trackColor($r('app.color.divider'))
                .onChange((newValue: number, mode: SliderChangeMode): void => {
                  if (mode === SliderChangeMode.End) {
                    this.onRecoverPollChange(Math.round(newValue));
                  }
                })
                .width('100%')
            }
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(10)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .width('100%')
            .margin({ bottom: 16 })

            // Conduit 借鉴：定时任务列表（/api/jobs）
            if (this.jobList.length > 0) {
              Text($r('app.string.jobs_section'))
                .fontSize(13)
                .fontColor($r('app.color.text_hint'))
                .padding({ top: 4, bottom: 8 })
                .alignSelf(ItemAlign.Start)

              Column() {
                ForEach(this.jobList, (j: JobInfo) => {
                  Row() {
                    // 状态点：ok=绿 / failed=红 / 未执行=灰
                    Circle()
                      .width(8)
                      .height(8)
                      .fill(j.lastStatus === 'ok' ? $r('app.color.success') :
                            j.lastStatus === 'failed' ? $r('app.color.danger') :
                            $r('app.color.divider'))
                    Column() {
                      Text(j.name)
                        .fontSize(13)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(j.schedule !== '' ? j.schedule : '')
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    .margin({ left: 8 })

                    if (!j.enabled) {
                      Text($r('app.string.job_disabled'))
                        .fontSize(10)
                        .fontColor($r('app.color.text_hint'))
                    }
                  }
                  .width('100%')
                  .height(52)
                  .padding({ left: 4, right: 4 })

                  if (j.name !== '') {
                    Divider().strokeWidth(0.5).color($r('app.color.divider'))
                  }
                }, (j: JobInfo) => j.id)
              }
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(10)
              .padding({ left: 16, right: 16 })
              .width('100%')
              .margin({ bottom: 16 })
            }

            // ===== 2026-11-18 关于/开源/安全信息已拆到 AboutPage 单列 tab =====
            // SettingsPage 现在只保留：首次接入+扫码 / 通用 / 高级 / 档案列表。
            // 只读信息（App 版本/构建号/API 契约/网关地址/网关版本/
            // MIT 许可证/网关 Key 状态）在「关于」tab 查看。

            Text($r('app.string.settings_saved'))
              .fontSize(14)
              .margin({ top: 8, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            if (this.profileList.length === 0) {
              Text($r('app.string.settings_none'))
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .alignSelf(ItemAlign.Start)
            }

            ForEach(this.profileList, (p: ServerProfile) => {
              Column() {
                Row() {
                  Column() {
                    Text(p.name)
                      .fontSize(14)
                    Text(p.baseUrl === '' ? $r('app.string.settings_no_url') : p.baseUrl)
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ top: 2 })
                    Text(p.network === NetworkKind.TAILNET ? $r('app.string.net_tailnet') : $r('app.string.net_lan'))
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ top: 2 })
                    if (p.pf !== '') {
                      Text('Profile：' + p.pf)
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                        .margin({ top: 2 })
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (p.id === this.v().activeId) {
                    Text($r('app.string.settings_active'))
                      .fontSize(11)
                      .fontColor(accentPrimary())
                      .margin({ right: 8 })
                  }

                  Button(this.v().diagBusy && this.v().diagId === p.id ? $r('app.string.diag_busy') : $r('app.string.diag'))
                    .fontSize(12)
                    .height(32)
                    .margin({ right: 8 })
                    .onClick(() => {
                      this.onDiagnose(p.id);
                    })
                  if (p.id !== this.v().activeId) {
                    Button($r('app.string.activate'))
                      .fontSize(12)
                      .height(32)
                      .margin({ right: 8 })
                      .onClick(() => {
                        let s: SettingsVM = this.v();
                        s.setActive(p.id).then((ok: boolean): void => {
                          if (ok) {
                            this.notifyProfileChanged();
                            // 激活档案变更：刷新关于/安全信息区（地址/Key 状态/网关版本）。
                            s.loadAbout().catch((err2: Error): void => {
                              LogSafe.w(TAG, 'loadAbout failed: %{public}s', err2.message);
                            });
                          }
                        });
                      })
                  }
                  Button($r('app.string.delete'))
                    .fontSize(12)
                    .height(32)
                    .onClick(() => {
                      this.confirmDelete(p.id, p.name);
                    })
                }
                .width('100%')

                if (this.v().diagId === p.id) {
                  Text() {
                    // 留白-02 收口：基础句走 $r()（跟随 app 首选语言），动态值后缀跨语言通用。
                    Span(this.diagBaseRes(this.v().diagStatus))
                    Span(this.diagSuffixOf())
                  }
                    .fontSize(11)
                    .fontColor(this.diagColor())
                    .margin({ top: 6 })
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(10)
              .backgroundColor($r('app.color.bg_card'))
              .margin({ bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            // Content-addressed key (batch2-r2 P0-B): ForEach re-creates
            // an item only when its key changes; keying on p.id alone
            // kept the old row after edit/activate. The key covers every
            // rendered field plus the active flag, so any visible change
            // rebuilds exactly the affected rows; the diagnose state is
            // joined last so diagId/diagStatus changes rebuild the row.
            }, (p: ServerProfile) => p.id + '|' + p.name + '|' + p.baseUrl + '|' +
              String(p.network) + '|' + (p.id === this.v().activeId ? '1' : '0') + '|' +
              (this.v().diagId === p.id ? String(this.v().diagStatus) : ''))

            Text($r('app.string.settings_token_note'))
              .fontSize(11)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 12, bottom: 16 })
              .alignSelf(ItemAlign.Start)

            // ===== 第 4 组：账号（退出登录）=====
            // 只在「本机存有当前网关会话」时出现；退出后闸门接管聊天页。
            if (this.hasSession) {
              Text($r('app.string.settings_group_account'))
                .fontSize(13)
                .fontColor($r('app.color.text_hint'))
                .padding({ top: 8, bottom: 8 })
                .alignSelf(ItemAlign.Start)

              Text($r('app.string.settings_signout'))
                .fontSize(15)
                .fontColor($r('app.color.danger'))
                .width('100%')
                .height(48)
                .textAlign(TextAlign.Center)
                .backgroundColor($r('app.color.bg_card'))
                .borderRadius(10)
                .onClick(() => {
                  this.confirmSignOut();
                })

              Text($r('app.string.settings_signout_hint'))
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 8, bottom: 16 })
                .alignSelf(ItemAlign.Start)
            }
          }
          .padding({ left: 12, right: 12 })
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
