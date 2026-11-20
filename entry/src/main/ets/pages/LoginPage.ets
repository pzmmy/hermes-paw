// =====================================================================
// pages/LoginPage.ets — 登录页（P2）：邮箱 + 6 位验证码
//
// 闸门语义（设计文档 §9）：未登录态下数据面唯一入口。成功 →
// PROFILE_CHANGED_EVENT_ID → Index 抬 profileVer → ChatPage 重新
// initChat → connect 恢复会话 → /me 校验 → 登录态（闸门隐去）。
// 仅在有激活 profile 时可达（ChatPage 闸门卡片入口）。
// =====================================================================

import { Msg } from '../utils/Msg';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { emitter } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { DbHelper } from '../store/DbHelper';
import { LoginVM } from '../viewmodel/LoginVM';
import { SettingsVM } from '../viewmodel/SettingsVM';
import { ServerProfile } from '../model/Profile';
import { PROFILE_CHANGED_EVENT_ID } from './ScanPage';
import { accentPrimary } from '../theme/Accent';

const TAG: string = 'LoginPage';

@Entry
@Component
struct LoginPage {
  @State vm: LoginVM | null = null;
  /** 经 vm.onUiChange 抬升（同 ChatPage.uiVersion 模式）。 */
  @State uiVersion: number = 0;
  @State emailText: string = '';
  @State codeText: string = '';
  @State bootError: string = '';
  private ctxRef: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    // getContext 自 API 18 弃用；UIAbility 页宿主上下文 = UIAbilityContext。
    let ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ctxRef = ctx;
    DbHelper.get(ctx).then((db: DbHelper) => {
      this.initPage(ctx, db);
    }).catch((err: Error): void => {
      this.bootError = Msg.t('m_chat_init_fail') + err.message;
    });
  }

  aboutToDisappear(): void {
    if (this.vm !== null) {
      this.vm.destroy();
    }
  }

  private initPage(ctx: common.UIAbilityContext, db: DbHelper): void {
    let svm: SettingsVM = new SettingsVM(ctx, db);
    svm.load().then(() => {
      let prof: ServerProfile | null = svm.getActiveProfile();
      if (prof === null) {
        // 防御：闸门只在有激活 profile 时路由到此页。
        this.bootError = Msg.t('m_login_no_server');
        return;
      }
      let vm: LoginVM = new LoginVM(ctx, prof);
      let page: LoginPage = this;
      vm.onUiChange = (): void => {
        page.uiVersion = page.uiVersion + 1;
      };
      this.vm = vm;
      vm.init().then((): void => {
        this.emailText = vm.email;
      }).catch((err: Error): void => {
        LogSafe.w(TAG, 'login vm init failed: %{public}s', err.message);
      });
    }).catch((err: Error): void => {
      this.bootError = Msg.t('m_chat_init_fail') + err.message;
    });
  }

  private gotoBack(): void {
    router.back();
  }

  private onSendCode(): void {
    let vm: LoginVM | null = this.vm;
    if (vm === null) {
      return;
    }
    vm.email = this.emailText;
    vm.sendCode().catch((err: Error): void => {
      LogSafe.e(TAG, 'sendCode threw: %{public}s', err.message);
    });
  }

  private onVerify(): void {
    let vm: LoginVM | null = this.vm;
    if (vm === null) {
      return;
    }
    vm.email = this.emailText;
    vm.code = this.codeText;
    vm.login().then((ok: boolean): void => {
      if (ok) {
        LogSafe.i(TAG, 'login ok — emitting profile change');
        let ev: emitter.InnerEvent = { eventId: PROFILE_CHANGED_EVENT_ID };
        emitter.emit(ev);
        router.back();
      }
    }).catch((err: Error): void => {
      LogSafe.e(TAG, 'login threw: %{public}s', err.message);
    });
  }

  private sendLabel(): string | Resource {
    let vm: LoginVM | null = this.vm;
    if (vm !== null && vm.countdownSec > 0) {
      return $r('app.string.login_resend_fmt', String(vm.countdownSec));
    }
    return $r('app.string.login_send');
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.back'))
          .fontSize(13)
          .height(36)
          .backgroundColor($r('app.color.bg_subtle'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(8)
          .onClick(() => {
            this.gotoBack();
          })
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })

      if (this.vm === null) {
        if (this.bootError !== '') {
          Text(this.bootError)
            .fontSize(14)
            .fontColor($r('app.color.danger'))
        } else {
          // 加载骨架（同 ChatPage 模式）。
          Column() {
            Row() {
              Column().width('40%').height(12).borderRadius(6).backgroundColor($r('app.color.divider'))
            }
            .width('80%')
            .margin({ bottom: 16 })
            Row() {
              Column().width('60%').height(12).borderRadius(6).backgroundColor($r('app.color.divider'))
            }
            .width('80%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      } else {
        Column() {
          Text('🐾')
            .fontSize(36)
            .margin({ bottom: 8 })
          Text($r('app.string.login_sub_fmt', this.vm.serverLabel))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: 24 })
          TextInput({ text: this.emailText, placeholder: $r('app.string.login_email_ph') })
            .fontSize(15)
            .height(48)
            .backgroundColor($r('app.color.bg_page'))
            .borderRadius(8)
            .margin({ bottom: 12 })
            .onChange((v: string): void => {
              this.emailText = v;
            })
          Button(this.sendLabel())
            .fontSize(14)
            .height(44)
            .borderRadius(8)
            .backgroundColor(this.vm.countdownSec > 0 ? $r('app.color.divider') : accentPrimary())
            .fontColor(this.vm.countdownSec > 0 ? $r('app.color.text_secondary') : $r('app.color.text_inverse'))
            .enabled(!(this.vm.sending || this.vm.verifying || this.vm.countdownSec > 0))
            .width('100%')
            .margin({ bottom: 20 })
            .onClick(() => {
              this.onSendCode();
            })
          TextInput({ text: this.codeText, placeholder: $r('app.string.login_code_ph') })
            .fontSize(18)
            .height(52)
            .backgroundColor($r('app.color.bg_page'))
            .borderRadius(8)
            .margin({ bottom: 12 })
            .onChange((v: string): void => {
              this.codeText = this.vm !== null ? this.vm.onCodeInput(v) : v;
            })
          Button($r('app.string.login_verify'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .height(48)
            .borderRadius(8)
            .backgroundColor(accentPrimary())
            .fontColor($r('app.color.text_inverse'))
            .enabled(!(this.vm.sending || this.vm.verifying))
            .width('100%')
            .margin({ bottom: 16 })
            .onClick(() => {
              this.onVerify();
            })
          if (this.vm.error !== '') {
            Text(this.vm.error)
              .fontSize(13)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 8 })
          }
          Text($r('app.string.login_hint'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .padding(24)
        .width('88%')
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(16)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
