import { accentPrimary } from '../../theme/Accent';

// pages/chat/LoginGate.ets —— 未登录闸门覆盖层（设计文档 §9 / P2）
// EN: the "not signed in" overlay: an opaque full-screen layer that covers the
//     whole chat data plane while authMode === 'loggedOut'.
//
// 从 ChatPage.build() 里整块搬出来，样式一字未改：
//   Column .width('100%') .height('100%') .backgroundColor(bg_page)
//   .justifyContent(Center) .alignItems(Center) .padding(32)
//   内容自下而上：可选错误行（danger 13px）→ 🔒 32px → 标题 17px 粗体 →
//   说明 13px 居中 → 80% 宽、44 高的主色按钮。
//
// 为什么整层是 opaque（不透明）+ 铺满：这不是弹窗，是数据面闸门——未登录时
// 底下的消息列表不该被看见，也不该能点。登录成功后 profileVer 抬升 → 重连 →
// /me 通过 → authMode 翻转为 loggedIn → 父页不再创建本组件。
//
// 显示时机：父页用 `if (vm !== null && v.authMode === 'loggedOut')` 控制。

@Component
export struct LoginGate {
  // 空串时不占位（原实现的 if 语义）。
  @Prop errText: string = '';

  onOpenLogin: () => void = (): void => {
  };

  build() {
    Column() {
      if (this.errText !== '') {
        Text(this.errText)
          .fontSize(13)
          .fontColor($r('app.color.danger'))
          .margin({ bottom: 16 })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      Text('🔒')
        .fontSize(32)
        .margin({ bottom: 12 })
      Text($r('app.string.login_chat_gate_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8 })
      Text($r('app.string.login_chat_gate_msg'))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .margin({ bottom: 24 })
      Button($r('app.string.login_chat_gate_btn'))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .height(44)
        .borderRadius(8)
        .backgroundColor(accentPrimary())
        .fontColor($r('app.color.text_inverse'))
        .width('80%')
        .onClick(() => {
          this.onOpenLogin();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(32)
  }
}
