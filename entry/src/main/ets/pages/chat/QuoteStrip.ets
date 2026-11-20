// pages/chat/QuoteStrip.ets —— 引用回复条（S2-b）
// EN: the "replying to" strip: a one-line preview of the quoted bubble with a ✕
//     to drop the quote before sending.
//
// 从 ChatPage.build() 整块搬出来，样式一字未改：
//   Row .width('100%') .padding({ left: 12, right: 12, bottom: 4 })
//   .backgroundColor(bg_subtle) .borderRadius(8)
//   「回复」12px hint → 引用正文 12px hint、单行省略、layoutWeight(1) → ✕ 13px。
//
// 父页用 `if (this.hasQuote())` 控制创建（与原来同语义：无引用不占位）。

@Component
export struct QuoteStrip {
  @Prop text: string = '';

  onClear: () => void = (): void => {
  };

  build() {
    Row() {
      Text($r('app.string.replying'))
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })
      Text('✕')
        .fontSize(13)
        .fontColor($r('app.color.text_hint'))
        .margin({ left: 8 })
        .onClick((): void => { this.onClear(); })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 4 })
    .backgroundColor($r('app.color.bg_subtle'))
    .borderRadius(8)
  }
}
