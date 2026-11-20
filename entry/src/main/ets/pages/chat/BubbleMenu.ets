import { accentPrimary, accentTint } from '../../theme/Accent';

// pages/chat/BubbleMenu.ets —— 气泡操作栏（S2-b）
// EN: the contextual action bar shown above the input row for the selected
//     bubble: copy / resend / stop / handle approval / quote / delete / close.
//
// 从 ChatPage.build() 整块搬出来，样式与按钮顺序一字未改：
//   复制（有正文才有）→ 重发（仅用户气泡）→ 停止生成（跑着才有）
//   → 处理审批（有待审批才有）→ 引用（有正文才有）→ 删除 → ✕ 关闭
//   全部 height(36)、layoutWeight(1)、间距 6；✕ 固定 36 宽。
//
// 为什么把这些「有没有」判断变成 @Prop 布尔值：
//   原始代码在 build() 里直接读 this.menuHasText() / this.menuIsUser() /
//   this.v().busy / this.v().pendingApproval，其中 pendingApproval 需要
//   非空判断（类型收窄），而 build() 不允许局部语句（10905209）。
//   父页在方法层把四个条件算成布尔，组件只按布尔决定画不画。
//
// 显示时机：父页仍用 `if (this.menuFor !== null)` 控制创建。

@Component
export struct BubbleMenu {
  @Prop hasText: boolean = false;
  @Prop isUser: boolean = false;
  @Prop busy: boolean = false;
  @Prop hasApproval: boolean = false;

  onCopy: () => void = (): void => {
  };
  onResend: () => void = (): void => {
  };
  onStop: () => void = (): void => {
  };
  onApprove: () => void = (): void => {
  };
  onQuote: () => void = (): void => {
  };
  onDelete: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };

  build() {
    Row() {
      if (this.hasText) {
        Button($r('app.string.act_copy'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .backgroundColor($r('app.color.divider'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => { this.onCopy(); })
      }
      if (this.isUser) {
        Button($r('app.string.act_resend'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .backgroundColor(accentTint())
          .fontColor(accentPrimary())
          .onClick((): void => { this.onResend(); })
      }
      if (this.busy) {
        Button($r('app.string.act_stop_gen'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .backgroundColor($r('app.color.danger'))
          .fontColor($r('app.color.text_inverse'))
          .onClick((): void => { this.onStop(); })
      }
      if (this.hasApproval) {
        Button($r('app.string.act_handle_appr'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .backgroundColor($r('app.color.warning_amber'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => { this.onApprove(); })
      }
      if (this.hasText) {
        Button($r('app.string.act_quote'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .backgroundColor($r('app.color.divider'))
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => { this.onQuote(); })
      }
      Button($r('app.string.act_delete'))
        .fontSize(13)
        .height(36)
        .layoutWeight(1)
        .margin({ right: 6 })
        .backgroundColor($r('app.color.divider'))
        .fontColor($r('app.color.danger'))
        .onClick((): void => { this.onDelete(); })
      Button('✕')
        .fontSize(13)
        .height(36)
        .width(36)
        .backgroundColor($r('app.color.text_hint'))
        .fontColor($r('app.color.text_inverse'))
        .onClick((): void => { this.onClose(); })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 6 })
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius(10)
  }
}
