import { accentPrimary } from '../../theme/Accent';

// pages/chat/StatusBar.ets —— 等待期三态状态条（A1/S6c）
// EN: the waiting-phase status bar: animated dots while a run is in flight,
//     plus the one-line status text (queued / running / finalising).
//
// 从 ChatPage.build() 里整块搬出来，样式一字未改：
//   Row .width('100%') .padding({ left: 12, right: 12, top: 6, bottom: 2 })
//   忙碌时左侧画 runDots()（primary 色 13px），右侧状态文字 12px secondary 色。
//
// 为什么 dots 和 text 都由父页算好传进来：
//   build() 只允许 UI 组件语法（10905209），不能写局部变量；runDots() 依赖
//   定时器 tick、statusBarText() 依赖 run 状态与收口提示的 3 秒窗口，两者都在
//   父页的方法层。这里只负责画。
//
// 显示时机：父页用 `if (this.tick >= 0 && this.statusBarText() !== '')` 控制
// 是否创建；读 tick（@State）让 3 秒窗口到期后父页重绘、本组件随之消失。

@Component
export struct StatusBar {
  @Prop text: string = '';
  @Prop busy: boolean = false;
  @Prop dots: string = '';

  build() {
    Row() {
      if (this.busy) {
        Text(this.dots)
          .fontSize(13)
          .fontColor(accentPrimary())
      }
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 2 })
  }
}
