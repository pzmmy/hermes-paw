// =====================================================================
// pages/ScanPage.ets — QR setup page (S1, plan §4.7)
//
// Entry: SettingsPage 「扫码配置」 (router.pushUrl). Three inputs
// (ScanVM): camera scan (Scan Kit default UI), album decode
// (PhotoViewPicker + detectBarcode.decode), paste string.
// On save: import profile + key, activate, emit PROFILE_CHANGED_EVENT
// (Index bumps profileVer -> chat re-initializes; SettingsPage
// reloads its list), then router.back().
// No new permissions: Scan Kit default UI and PhotoViewPicker are
// out-of-sandbox system UIs (module.json5 untouched).
// =====================================================================
import { Msg } from '../utils/Msg';
import { router } from '@kit.ArkUI';
import { emitter } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { LogSafe } from '../utils/LogSafe';
import { DbHelper } from '../store/DbHelper';
import { SettingsVM } from '../viewmodel/SettingsVM';
import { ProbeResult, ScanVM } from '../viewmodel/ScanVM';
import { accentPrimary } from '../theme/Accent';

const TAG: string = 'ScanPage';

/** Emitted after a QR import. Subscribers: Index (bump profileVer),
 *  SettingsPage (reload profile list). */
export const PROFILE_CHANGED_EVENT_ID: number = 0x1001;

// Listed in main_pages.json -> must be @Entry (ArkTS 10905402).
@Entry
@Component
export struct ScanPage {
  @State vm: ScanVM | null = null;
  @State pasteText: string = '';
  @State showPaste: boolean = false;
  /** A4: confirm-stage key reveal toggle (default hidden/masked). */
  @State showKey: boolean = false;
  @State chosenHost: string = '';
  @State bootError: string = '';

  private profileEvent: emitter.InnerEvent = { eventId: PROFILE_CHANGED_EVENT_ID };

  aboutToAppear(): void {
    // E1: opened from the first-launch onboarding card (primary path =
    // paste) reveals the paste field by default via the pasteFirst param.
    let params: object | undefined = router.getParams();
    if (params !== undefined) {
      let rec: Record<string, string> = params as Record<string, string>;
      if (rec['pasteFirst'] === 'true') {
        this.showPaste = true;
      }
    }
    let ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    DbHelper.get(ctx).then((db: DbHelper) => {
      // Own SettingsVM instance: importSetup writes the same DB rows
      // (profiles JSON + active id) that Index/ChatPage read on
      // re-initialization — sync is by reload, not shared reference.
      let svm: SettingsVM = new SettingsVM(ctx, db);
      let vm: ScanVM = new ScanVM(ctx, svm);
      this.vm = vm;
      svm.load().catch((err: Error) => {
        // importSetup re-loads itself as a guard; log only.
        LogSafe.w(TAG, 'svm load failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      // 留白-01 收口：启动错误文案走 i18n（占位符 %s = 错误消息）。
      try {
        this.bootError = ctx.resourceManager.getStringSync($r('app.string.db_init_failed_fmt'), err.message);
      } catch (e2) {
        this.bootError = Msg.t('m_about_db_init_fail') + err.message;
      }
    });
  }

  // No aboutToDisappear: this page only EMITS profileEvent; off() here
  // would remove Index/SettingsPage subscriptions for the same id.

  private onProbeTap(host: string): void {
    let v: ScanVM | null = this.vm;
    if (v === null) {
      return;
    }
    for (let i: number = 0; i < v.probes.length; i++) {
      if (v.probes[i].host === host && v.probes[i].ok) {
        this.chosenHost = host;
        return;
      }
    }
  }

  private save(): void {
    let v: ScanVM | null = this.vm;
    if (v === null || v.busy) {
      return;
    }
    let host: string = this.chosenHost;
    if (host === '') {
      // auto: first authenticated host (probes are in payload order)
      for (let i: number = 0; i < v.probes.length; i++) {
        if (v.probes[i].ok) {
          host = v.probes[i].host;
          break;
        }
      }
    }
    if (host === '' && v.probes.length > 0) {
      // fallback: allow saving if host is reachable but auth probe
      // failed (e.g. gateway 404 on /v1/models when profile not started)
      for (let i: number = 0; i < v.probes.length; i++) {
        if (v.probes[i].reachable) {
          host = v.probes[i].host;
          v.notice = Msg.t('m_scan_auth_warn');
          break;
        }
      }
    }
    if (host === '') {
      let context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      try {
        v.error = context.resourceManager.getStringSync($r('app.string.scan_no_gateway'));
      } catch (err) {
        let e: Error = err as Error;
        LogSafe.w(TAG, 'fmtScanError failed: %{public}s', e.message);
        v.error = Msg.t('m_scan_no_gateway');
      }
      return;
    }
    v.confirm(host).then((ok: boolean) => {
      if (ok) {
        this.emitProfileChanged();
        router.back();
      }
    });
  }

  private emitProfileChanged(): void {
    let data: emitter.EventData = { data: {} };
    emitter.emit(this.profileEvent, data);
  }

  /** A4: masked key for the confirm stage (first4…last4); short keys stay
   *  fully masked. Full key only via the explicit 显示 toggle (fullKey). */
  private maskedKey(): string {
    let v: ScanVM | null = this.vm;
    if (v === null || v.uri === null) {
      return '';
    }
    let k: string = v.uri.key;
    if (k.length <= 8) {
      return '****';
    }
    return k.substring(0, 4) + '…' + k.substring(k.length - 4);
  }

  /** A4: full key, shown only while the 显示 toggle is on. */
  private fullKey(): string {
    let v: ScanVM | null = this.vm;
    if (v === null || v.uri === null) {
      return '';
    }
    return v.uri.key;
  }

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.scan_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 6 })
      if (this.bootError !== '') {
        Text(this.bootError)
          .fontSize(12)
          .fontColor('#F44336')
          .width('100%')
      }
      if (this.vm === null && this.bootError === '') {
        Text($r('app.string.loading'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      } else if (this.vm !== null) {
        this.vmContent()
      }
      Blank()
      Button($r('app.string.back'))
        .width('92%')
        .height(38)
        .fontSize(13)
        .backgroundColor($r('app.color.chip_dark'))
        .borderRadius(8)
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 20 })
    .backgroundColor($r('app.color.scan_bg'))
  }

  @Builder
  vmContent() {
    if (this.vm !== null) {
      if (this.vm.error !== '') {
        Text(this.vm.error)
          .fontSize(12)
          .fontColor('#F44336')
          .width('100%')
      }
      if (this.vm.notice !== '') {
        Text(this.vm.notice)
          .fontSize(12)
          .fontColor($r('app.color.scan_text'))
          .width('100%')
      }

      if (this.vm.stage === 'idle' || this.vm.stage === 'parsing'
        || this.vm.stage === 'probing') {
        Row({ space: 10 }) {
          Button($r('app.string.scan_camera'))
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .backgroundColor(accentPrimary())
            .borderRadius(8)
            .enabled(!this.vm.busy)
            .onClick(() => {
              let v: ScanVM | null = this.vm;
              if (v !== null) {
                v.startScan();
              }
            })
          Button($r('app.string.scan_album'))
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .backgroundColor($r('app.color.success'))
            .borderRadius(8)
            .enabled(!this.vm.busy)
            .onClick(() => {
              let v: ScanVM | null = this.vm;
              if (v !== null) {
                v.pickAlbum();
              }
            })
          Button($r('app.string.scan_paste'))
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .backgroundColor($r('app.color.text_secondary'))
            .borderRadius(8)
            .enabled(!this.vm.busy)
            .onClick(() => {
              this.showPaste = !this.showPaste;
            })
        }
        .width('100%')
        if (this.showPaste) {
          TextInput({ text: this.pasteText, placeholder: $r('app.string.scan_paste_ph') })
            .fontSize(12)
            .height(40)
            .margin({ top: 4 })
            .onChange((v: string) => {
              this.pasteText = v;
            })
          // E2: how to get the config string (most first-time users have
          // none yet) — points at the Hermes server as the source.
          Text($r('app.string.scan_no_key_hint'))
            .fontSize(11)
            .fontColor($r('app.color.scan_text'))
            .margin({ top: 4 })
          Button($r('app.string.scan_parse'))
            .width('100%')
            .height(38)
            .fontSize(13)
            .margin({ top: 6 })
            .backgroundColor(accentPrimary())
            .borderRadius(8)
            .enabled(!this.vm.busy)
            .onClick(() => {
              let v: ScanVM | null = this.vm;
              if (v !== null) {
                v.paste(this.pasteText);
                this.pasteText = '';
              }
            })
        }
        if (this.vm.stage === 'probing') {
          Text($r('app.string.scan_probing'))
            .fontSize(12)
            .fontColor($r('app.color.scan_text'))
            .width('100%')
        }
        if (this.vm.stage === 'parsing') {
          Text($r('app.string.scan_parsing'))
            .fontSize(12)
            .fontColor($r('app.color.scan_text'))
            .width('100%')
        }
      }

      if (this.vm.stage === 'confirm' && this.vm.uri !== null) {
        Text($r('app.string.scan_confirm_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
        Text($r('app.string.name_row_fmt', this.vm.uri.name))
          .fontSize(13)
        if (this.vm.uri.pf !== '') {
          Text($r('app.string.profile_row_fmt', this.vm.uri.pf))
            .fontSize(13)
        }
        Text($r('app.string.transport_lan'))
          .fontSize(13)
        // A4: masked token row (first4…last4) + explicit 显示 toggle — the
        // raw key is never shown by default (transparency, not exposure).
        Row() {
          Text($r('app.string.key_row_fmt', (this.showKey ? this.fullKey() : this.maskedKey())))
            .fontSize(13)
            .fontColor($r('app.color.scan_warn_text'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.showKey ? $r('app.string.show_hide') : $r('app.string.show_show'))
            .fontSize(12)
            .fontColor($r('app.color.scan_text'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.showKey = !this.showKey;
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor($r('app.color.scan_card'))
        .borderRadius(6)
        Text($r('app.string.scan_gateway_hint'))
          .fontSize(12)
          .fontColor($r('app.color.scan_text'))
        ForEach(this.vm.probes, (probe: ProbeResult) => {
          Row() {
            Text(probe.host)
              .fontSize(13)
              .fontColor(probe.ok ? $r('app.color.text_inverse') : $r('app.color.text_secondary'))
              .layoutWeight(1)
            Text((probe.ok ? '✓ ' : '✗ ') + probe.detail)
              .fontSize(11)
              .fontColor(probe.ok ? '#66BB6A' : '#F44336')
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .backgroundColor(probe.ok ? '#1B2B1B' : '#26221E')
          .borderRadius(6)
          .onClick(() => {
            if (probe.ok) {
              this.onProbeTap(probe.host);
            }
          })
        }, (probe: ProbeResult) => probe.host)
        Button(this.vm.busy ? $r('app.string.scan_saving') : $r('app.string.scan_save'))
          .width('100%')
          .height(42)
          .fontSize(14)
          .margin({ top: 8 })
          .backgroundColor(accentPrimary())
          .borderRadius(8)
          .enabled(!this.vm.busy)
          .onClick(() => {
            this.save();
          })
      }
    }
  }
}
