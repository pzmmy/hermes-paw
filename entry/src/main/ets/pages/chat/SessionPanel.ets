import { MergedSession } from '../../viewmodel/SessionMerge';
import { Msg } from '../../utils/Msg';
import { accentPrimary, accentTint } from '../../theme/Accent';

// pages/chat/SessionPanel.ets —— 会话面板（本地 + 服务端合并列表）
// EN: the sessions overlay: local/server merged rows, search box, hide-empty
//     toggle, refresh, long-press to delete.
//
// 从 ChatPage.build()（当时单方法 1001 行）里整块搬出来，行为一字不改：
// 父页只负责算数据（visibleRows / emptySessionCount）和提供回调，
// 这里不持有 ChatVM，也不发请求。
//
// 状态全部单向：@Prop 数据 + 回调；勾选与搜索词也走回调回写父页的 @State，
// 避免 @Link 双向绑定在父子重建时出现回写顺序问题。

@Component
export struct SessionPanel {
  @Prop rows: MergedSession[] = [];
  @Prop loading: boolean = false;
  @Prop errText: string = '';
  @Prop emptyCount: number = 0;
  @Prop hideEmpty: boolean = false;
  @Prop sessionQuery: string = '';

  onToggleHide: () => void = (): void => {
  };
  onQueryChange: (v: string) => void = (v: string): void => {
  };
  onRefresh: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };
  onPick: (m: MergedSession) => void = (m: MergedSession): void => {
  };
  onRowLongPress: (m: MergedSession) => void = (m: MergedSession): void => {
  };
  fmtCount: (n: number) => string = (n: number): string => String(n);
  fmtTime: (tsSec: number) => string = (tsSec: number): string => '';

  build() {
    Column() {
      Row() {
        Text(Msg.t('m_chat_sessions'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        // 空会话过滤开关：数字来自父页算好的 emptyCount，点击回写父页 @State。
        Text(this.hideEmpty
          ? $r('app.string.filter_show_empty_fmt', String(this.emptyCount))
          : $r('app.string.filter_hide_empty_fmt', String(this.emptyCount)))
          .fontSize(12)
          .fontColor(this.hideEmpty ? '#757575' : accentPrimary())
          .margin({ right: 12 })
          .onClick(() => {
            this.onToggleHide();
          })
        Text(this.loading ? $r('app.string.refreshing') : $r('app.string.refresh'))
          .fontSize(13)
          .fontColor(accentPrimary())
          .margin({ right: 16 })
          .onClick(() => {
            this.onRefresh();
          })
        Text($r('app.string.close_panel'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 12, bottom: 8 })
      .backgroundColor($r('app.color.bg_page'))

      Row() {
        TextInput({ placeholder: Msg.t('m_chat_search_hint'), text: this.sessionQuery })
          .height(36)
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor('#F2F2F2')
          .borderRadius(8)
          .onChange((val: string) => {
            this.onQueryChange(val);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      if (this.errText !== '') {
        Column() {
          Text(this.errText)
            .fontSize(12)
            .fontColor($r('app.color.danger'))
          Text($r('app.string.diag_hint'))
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 4 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })
        .alignItems(HorizontalAlign.Start)
      }

      List() {
        if (this.rows.length === 0 && !this.loading) {
          ListItem() {
            Text(this.sessionQuery.trim() !== ''
              ? Msg.t('m_chat_no_match')
              : $r('app.string.no_server_sessions'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .padding(16)
          }
        }
        ForEach(this.rows, (m: MergedSession) => {
          ListItem() {
            Column() {
              Row() {
                Text(m.isLocal ? Msg.t('m_chat_tag_local') : Msg.t('m_chat_tag_server'))
                  .fontSize(10)
                  .fontColor(m.isLocal ? accentPrimary() : $r('app.color.text_secondary'))
                  .backgroundColor(m.isLocal ? accentTint() : '#EEEEEE')
                  .borderRadius(4)
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .height(18)
                  .margin({ right: 6 })
                Text(m.title !== '' ? m.title : $r('app.string.no_title'))
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              Text(m.lastActiveMs > 0
                ? (this.fmtCount(m.messageCount) + ' · '
                  + this.fmtTime(Math.floor(m.lastActiveMs / 1000)))
                : this.fmtCount(m.messageCount))
                .fontSize(11)
                .fontColor($r('app.color.text_hint'))
                .width('100%')
                .margin({ top: 2 })
              if (m.preview !== '') {
                Text(m.preview)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 2 })
              }
            }
            .padding(12)
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .onClick(() => {
              this.onPick(m);
            })
            .gesture(LongPressGesture({ repeat: false })
              .onAction((): void => {
                this.onRowLongPress(m);
              }))
          }
        }, (m: MergedSession) => m.key + '|' + m.title + '|' + String(m.lastActiveMs))
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 1, color: '#EEEEEE' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
