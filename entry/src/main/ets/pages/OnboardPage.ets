// =====================================================================
// pages/OnboardPage.ets — S1.5 Delegation-First onboarding (plan v2.6
// §4.8; v2.6.6 single tier: one kind of QR — no admin/user selection,
// no tier confirmation dialog).
//
// The user does exactly two things: paste the generated prompt into
// their own Hermes conversation, then scan the QR code Hermes sends
// back. All server-side setup is delegated to the Hermes agent —
// the prompt is goal-oriented (states the target ready state, the
// agent decides the steps itself; v2.6.6).
//
// UI contract (plan §4.8 App 改动 1, v2.6.6 修订):
//   - profile display name input (optional; drives the prompt live)
//   - prompt display: long-press copy via Text.copyOption(
//     CopyOptions.LocalDevice) — zero new permissions, zero
//     pasteboard import
//   - '收到二维码，去扫码' → pages/ScanPage (existing S1 three paths)
//   - back → SettingsPage
// =====================================================================
import { Msg } from '../utils/Msg';
import { router } from '@kit.ArkUI';
import { LogSafe } from '../utils/LogSafe';
import { buildOnboardPrompt } from '../util/OnboardPrompt';
import { accentPrimary } from '../theme/Accent';

const TAG: string = 'OnboardPage';

// BUG-002 (2026-11-17): official CopyOptions enum values (API 9+):
// None=0, InApp=1, LocalDevice=2, CrossDevice=3. The enum type does not
// resolve in the current build toolchain (verified in the real-device
// build round 2026-11-16), so the value is carried as a named constant
// instead of a magic number. Value stays LocalDevice: long-press copy
// works across apps on this device, not just inside this app.
const COPY_OPTION_LOCAL_DEVICE: number = 2;

@Entry
@Component
struct OnboardPage {
  @State profileName: string = Msg.t('m_onboard_my_hermes');
  @State promptText: string = '';

  aboutToAppear(): void {
    this.refreshPrompt();
  }

  private refreshPrompt(): void {
    this.promptText = buildOnboardPrompt(this.profileName);
  }

  private onGoScan(): void {
    router.pushUrl({ url: 'pages/ScanPage' }).catch((err: Error): void => {
      LogSafe.w(TAG, 'push ScanPage failed: %{public}s', err.message);
    });
  }

  private onBack(): void {
    router.back();
  }

  build() {
    Column() {
      Text($r('app.string.settings_first_onboard'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .padding(12)
        .alignSelf(ItemAlign.Start)

      Text($r('app.string.onb_prompt'))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 12, right: 12 })
        .width('100%')

      Scroll() {
        Column() {
          Text($r('app.string.onb_profile_label'))
            .fontSize(14)
            .alignSelf(ItemAlign.Start)

          TextInput({ placeholder: $r('app.string.onb_profile_ph'), text: this.profileName })
            .height(40)
            .margin({ top: 4, bottom: 12 })
            .onChange((val: string) => {
              this.profileName = val;
              this.refreshPrompt();
            })

          if (this.promptText !== '') {
            Text($r('app.string.onb_prompt_title'))
              .fontSize(13)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 4 })

            Text(this.promptText)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .padding(10)
              .borderRadius(8)
              .backgroundColor($r('app.color.bg_card'))
              .width('100%')
              // BUG-002: enum type unresolvable in this toolchain; named
              // constant keeps the official LocalDevice value (see header)
              .copyOption(COPY_OPTION_LOCAL_DEVICE)
              .margin({ bottom: 12 })
          }

          Button($r('app.string.onb_scan_btn'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .height(42)
            .backgroundColor(accentPrimary())
            .borderRadius(8)
            .width('100%')
            .margin({ bottom: 8 })
            .onClick(() => {
              this.onGoScan();
            })

          Button($r('app.string.back'))
            .fontSize(13)
            .height(38)
            .backgroundColor($r('app.color.chip_dark'))
            .borderRadius(8)
            .width('100%')
            .onClick(() => {
              this.onBack();
            })
        }
        .padding({ left: 12, right: 12, bottom: 16 })
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
