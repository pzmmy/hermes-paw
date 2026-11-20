import { accentPrimary, accentTint } from '../../theme/Accent';

// pages/chat/ChatNotice.ets —— 顶部三态提示条（错误 / 成功 / 提示）
// EN: the top notice area: a red error bar with inline actions, a dismissible
//     green success bar, and a tappable one-line notice. Mutually exclusive,
//     same precedence as the original if / else-if chain (error > success > notice).
//
// 从 ChatPage.build() 整块搬出来（96 行），样式与文案一字未改：
//   · 错误条：4px danger 竖条 + danger_soft 圆角卡（radius 10 / padding 8），
//     主文 14px 粗体 danger_deep、提示 12px hint，行内「重试」+「连接测试」
//   · 成功条：4×18 success 竖条 + success_soft 卡，**固定 height(40)**
//     （BUG-005：竖条 height('100%') 曾把整页聊天 UI 挤出屏幕）
//   · 提示条：12px 主色文字，点击即消
//
// 为什么外加一层 Column：自定义组件的 build() 只允许一个根节点，而原实现
// 是三个并列的 if 分支。三个都为空时 Column 高度为 0，与「什么都不渲染」等价。
//
// 互动全部走回调：组件不认识 ChatVM，也不判断 busy（父页在方法里查）。

@Component
export struct ChatNotice {
  @Prop errorText: string = '';
  @Prop successText: string = '';
  @Prop noticeText: string = '';

  onRetry: () => void = (): void => {
  };
  onTestConn: () => void = (): void => {
  };
  onClearSuccess: () => void = (): void => {
  };
  onClearNotice: () => void = (): void => {
  };

  build() {
    Column() {
      if (this.errorText !== '') {
        // U1/U2/A2: top warning bar — left color bar + light-red rounded
        // card; primary error 14px/500, secondary hint 12px; inline
        // 重试 (re-run connect) + 连接测试 (jump to Settings diagnose).
        Row() {
          Column()
            .width(4)
            .height('100%')
            .borderRadius(2)
            .backgroundColor($r('app.color.danger'))
          Column() {
            Text(this.errorText)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.danger_deep'))
            Text($r('app.string.diag_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 4 })
            Row() {
              Text($r('app.string.retry'))
                .fontSize(13)
                .fontColor($r('app.color.text_inverse'))
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .borderRadius(6)
                .backgroundColor($r('app.color.danger'))
                .margin({ top: 8, right: 8 })
                .onClick(() => {
                  this.onRetry();
                })
              Text($r('app.string.conn_test'))
                .fontSize(13)
                .fontColor(accentPrimary())
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .borderRadius(6)
                .backgroundColor(accentTint())
                .margin({ top: 8 })
                .onClick(() => {
                  this.onTestConn();
                })
            }
          }
          .padding(10)
          .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor($r('app.color.danger_soft'))
        .borderRadius(10)
        .padding(8)
      } else if (this.successText !== '') {
        // E3: green success bar (连接成功) — dismissible via ×.
        // BUG-005 回归修复: 绿色竖条 height('100%') 会撑满整个页面高度、
        // 把下方聊天 UI 挤到屏幕外（成功条常驻时聊天页不可用）。改为固定
        // 小高度 + Row 固定高度，成功条只是一条横幅，不占满整页。
        Row() {
          Column()
            .width(4)
            .height(18)
            .borderRadius(2)
            .backgroundColor($r('app.color.success'))
          Text(this.successText)
            .fontSize(13)
            .fontColor($r('app.color.success'))
            .layoutWeight(1)
            .padding(10)
          Text('×')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.onClearSuccess();
            })
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.success_soft'))
        .borderRadius(10)
        .padding(4)
      } else if (this.noticeText !== '') {
        Text(this.noticeText)
          .fontSize(12)
          .fontColor(accentPrimary())
          .padding(8)
          .width('100%')
          .onClick(() => {
            this.onClearNotice();
          })
      }
    }
    .width('100%')
  }
}
