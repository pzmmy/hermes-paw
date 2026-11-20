// pages/chat/AttachmentStrip.ets —— 待发图片条（S2-a）
// EN: the pending-attachment strip: 56x56 thumbnails of album picks, each with
//     a ✕ badge to remove it before sending.
//
// 从 ChatPage.build() 整块搬出来，样式一字未改：
//   Row .width('100%') .padding({ left: 12, right: 12, bottom: 4 })
//   每个缩略图 56×56、Cover、圆角 8；✕ 角标 18×18 半透明遮罩、margin 负值外挂。
//
// 父页用 `if (v.pendingImages.length > 0)` 控制是否创建（与原来同语义：
// 空数组时不占位）。

@Component
export struct AttachmentStrip {
  @Prop uris: string[] = [];

  onRemove: (uri: string) => void = (uri: string): void => {
  };

  build() {
    Row() {
      ForEach(this.uris, (uri: string) => {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(uri)
            .width(56)
            .height(56)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
          Text('✕')
            .fontSize(10)
            .fontColor($r('app.color.text_inverse'))
            .backgroundColor($r('app.color.overlay'))
            .borderRadius(9)
            .width(18)
            .height(18)
            .textAlign(TextAlign.Center)
            .margin({ top: -4, right: -4 })
            .onClick(() => {
              this.onRemove(uri);
            })
        }
        .margin({ right: 8 })
      }, (uri: string) => uri)
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 4 })
  }
}
