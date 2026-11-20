@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('Test Ability Index')
        .fontSize(16)
        .fontColor('#333333')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
