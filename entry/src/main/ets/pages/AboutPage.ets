// =====================================================================
// pages/AboutPage.ets — 关于页（只读信息区）。
//
// 2026-11-18 从 SettingsPage 拆分出来单列一个 tab（对话/设置/关于），
// 解决"设置页内容设置与关于混杂"问题。本页只渲染只读信息：
// 关于（App 版本/构建号/API 契约/网关地址/网关版本）+
// 开源信息（致谢/MIT 许可证/第三方依赖）+ 安全信息（网关 Key 状态）。
//
// 数据源：复用 SettingsVM 的 loadAbout()（与 SettingsPage 共享同一 VM
// 实例的 about 字段），激活档案变更时由 Index 的 onProfileChanged 触发
// 本页重新 loadAbout()。
// =====================================================================
import { Msg } from '../utils/Msg';
import { common } from '@kit.AbilityKit';
import { LogSafe } from '../utils/LogSafe';
import { DbHelper } from '../store/DbHelper';
import { SettingsVM, KeyState, GwVersionState } from '../viewmodel/SettingsVM';
import { ApiClient, API_CONTRACT_VERSION } from '../net/ApiClient';
import { accentPrimary } from '../theme/Accent';

const TAG: string = 'AboutPage';

/** BUG-002 pattern (same as SettingsPage): CopyOptions enum 不解析，
 *  用命名常量。LocalDevice=2：长按复制跨应用可用。 */
const COPY_OPTION_LOCAL_DEVICE: number = 2;

/** MIT 许可证全文（嵌入常量，零依赖；仓库 LICENSE 变更时需同步）。 */
const LICENSE_MIT: string =
  'MIT License' +
  '' +
  'Copyright (c) 2026 HermesPaw' +
  '' +
  'Permission is hereby granted, free of charge, to any person obtaining a copy' +
  'of this software and associated documentation files (the "Software"), to deal' +
  'in the Software without restriction, including without limitation the rights' +
  'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell' +
  'copies of the Software, and to permit persons to whom the Software is' +
  'furnished to do so, subject to the following conditions:' +
  '' +
  'The above copyright notice and this permission notice shall be included in all' +
  'copies or substantial portions of the Software.' +
  '' +
  'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR' +
  'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,' +
  'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE' +
  'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER' +
  'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,' +
  'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE' +
  'SOFTWARE.';

@Component
export struct AboutPage {
  @State vm: SettingsVM | null = null;
  @State bootError: string = '';
  /** Option B 开源信息行：MIT 许可证全文展开/收起状态。 */
  @State osLicenseOpen: boolean = false;

  aboutToAppear(): void {
    let ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    DbHelper.get(ctx).then((db: DbHelper): void => {
      let svm: SettingsVM = new SettingsVM(ctx, db);
      this.vm = svm;
      // 复用 SettingsVM.loadAbout()：装配只读信息行（版本/构建号/网关地址/
      // Key 状态/网关版本），各段失败自降级，不 reject。
      svm.load().then((): void => {
        svm.loadAbout().catch((err: Error): void => {
          LogSafe.w(TAG, 'loadAbout failed: %{public}s', err.message);
        });
      }).catch((err: Error): void => {
        try {
          this.bootError = ctx.resourceManager.getStringSync($r('app.string.db_init_failed_fmt'), err.message);
        } catch (e2) {
          this.bootError = Msg.t('m_about_db_init_fail') + err.message;
        }
      });
    }).catch((err: Error): void => {
      LogSafe.w(TAG, 'DbHelper.get failed: %{public}s', (err as Error).message);
    });
  }

  private v(): SettingsVM {
    return this.vm as SettingsVM;
  }

  // 2026-11-18 精简：以下方法已删（对应 UI 行已删）：
  // aboutAppVersionText / aboutBuildText（bundle 拿不到值，空）
  // aboutGwVersionText（/health 未提供）
  // securityKeyText / securityKeyColor（与配置页重复）
  // 只保留 API 契约行（API_CONTRACT_VERSION 常量直接渲染，无需方法）。

  build() {
    Column() {
      if (this.vm === null) {
        Text(this.bootError !== '' ? this.bootError : $r('app.string.loading'))
          .fontSize(14)
      } else {
        Text($r('app.string.tab_about'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .padding(12)
          .alignSelf(ItemAlign.Start)

        Scroll() {
          Column() {
            // ===== 第 1 组：关于（只读信息区）=====
            Text($r('app.string.settings_group_about'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 16, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            // 2026-11-18 精简：App 版本/构建号（bundle 拿不到值，空）、
            // hermes-agent 版本（/health 未提供，显示「未提供」）、网关 Key
            // 状态（与配置页重复）均已删。只保留 API 契约行（有值、不重复）。
            Column() {
              Row() {
                Text($r('app.string.about_api_contract'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text(API_CONTRACT_VERSION)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .height(52)
            }
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(10)
            .padding({ left: 16, right: 16 })
            .width('100%')
            .margin({ bottom: 16 })

            // ===== 第 2 组：开源信息（只读 + 许可证全文展开）=====
            Text($r('app.string.settings_group_opensource'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .padding({ top: 4, bottom: 8 })
              .alignSelf(ItemAlign.Start)

            Column() {
              Row() {
                Text($r('app.string.os_ack'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text($r('app.string.os_ack_value'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .height(52)

              Divider().strokeWidth(0.5).color($r('app.color.divider'))

              Row() {
                Text($r('app.string.os_license'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text($r('app.string.os_license_value'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.osLicenseOpen ? $r('app.string.os_license_collapse') : $r('app.string.os_license_view'))
                  .fontSize(12)
                  .fontColor(accentPrimary())
                  .margin({ left: 8 })
              }
              .width('100%')
              .height(52)
              .onClick((): void => { this.osLicenseOpen = !this.osLicenseOpen; })

              if (this.osLicenseOpen) {
                Text(LICENSE_MIT)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .lineHeight(16)
                  .copyOption(COPY_OPTION_LOCAL_DEVICE)
                  .padding(12)
                  .backgroundColor($r('app.color.bg_page'))
                  .borderRadius(8)
                  .width('100%')
                  .margin({ top: 4, bottom: 8 })
              }

              Divider().strokeWidth(0.5).color($r('app.color.divider'))

              Row() {
                Text($r('app.string.os_third_party'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text($r('app.string.os_third_party_none'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .height(52)
            }
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(10)
            .padding({ left: 16, right: 16 })
            .width('100%')
            .margin({ bottom: 16 })

            // 2026-11-18：安全信息组（网关 Key 状态）已删——与配置页重复。
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
