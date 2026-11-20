import { Msg } from '../../utils/Msg';

// pages/chat/ApprovalCard.ets —— 审批卡（四选一 + 倒计时）
// EN: the approval card: command text, human description, countdown/kind
//     status line, and the four choices (once / session / always / deny).
//
// 从 ChatPage.build() 整块搬出来，样式与文案一字不改：
//   .padding(12) .borderRadius(10) .backgroundColor(warning_soft) .width('92%')
//   .margin({ top: 8, bottom: 8 })，四个按钮 height(36)、等宽、间距 6，
//   deny 用 danger 底色。
//
// 为什么把三行文本算在父页、以 @Prop 传进来：
//   build() 里只允许 UI 组件语法（10905209），不能写局部变量；而
//   `this.v().pendingApproval !== null` 的收窄在重复访问时不会保持，
//   所以收窄只能发生在方法层。父页的 approvalCommand() /
//   approvalDescription() / approvalStatusText() 正是做这件事的地方。
//   这里只负责画，不碰 ChatVM、不认识 ApprovalControl。
//
// 显示时机：父页用 `if (v.pendingApproval !== null)` 控制是否创建本组件，
// 所以本组件内部不再判断可见性——被创建即代表该显示。

@Component
export struct ApprovalCard {
  @Prop command: string = '';
  @Prop description: string = '';
  @Prop statusText: string = '';

  // 四个按钮共用一条回调，父页按 choice 分发（VM 负责校验 + 发请求）。
  onChoice: (choice: string) => void = (choice: string): void => {
  };

  build() {
    Column() {
      Text($r('app.string.approval_title'))
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      if (this.command !== '') {
        Text(this.command)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }
      if (this.description !== '') {
        Text(this.description)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 2 })
      }
      Text(this.statusText)
        .fontSize(11)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
        .margin({ top: 4 })
      Row() {
        Button($r('app.string.appr_once'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .onClick(() => {
            this.onChoice('once');
          })
        Button($r('app.string.appr_session'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .onClick(() => {
            this.onChoice('session');
          })
        Button($r('app.string.appr_always'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .margin({ right: 6 })
          .onClick(() => {
            this.onChoice('always');
          })
        Button($r('app.string.appr_deny'))
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor($r('app.color.danger'))
          .fontColor($r('app.color.text_inverse'))
          .onClick(() => {
            this.onChoice('deny');
          })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .padding(12)
    .borderRadius(10)
    .backgroundColor($r('app.color.warning_soft'))
    .width('92%')
    .margin({ top: 8, bottom: 8 })
  }
}
