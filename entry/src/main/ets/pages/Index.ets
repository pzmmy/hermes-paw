// =====================================================================
// pages/Index.ets — root page: 对话 (chat) / 设置 (settings) tabs.
//
// profileVer is bumped whenever the settings page changes a server
// profile (save/activate/reset); the chat page re-initializes against
// the new server via @Prop + @Watch (batch2 P0-C: switching servers
// mid-session must not mix server contexts).
// S1: a QR import on ScanPage emits PROFILE_CHANGED_EVENT_ID — bumped
// here too, so the chat tab picks up the newly activated profile.
// =====================================================================
import { emitter } from '@kit.BasicServicesKit';
import { ChatPage } from './ChatPage';
import { SettingsPage } from './SettingsPage';
import { AboutPage } from './AboutPage';
import { PROFILE_CHANGED_EVENT_ID } from './ScanPage';

@Entry
@Component
struct Index {
  @State profileVer: number = 0;

  aboutToAppear(): void {
    emitter.on({ eventId: PROFILE_CHANGED_EVENT_ID }, (): void => {
      this.profileVer = this.profileVer + 1;
    });
  }

  aboutToDisappear(): void {
    emitter.off(PROFILE_CHANGED_EVENT_ID);
  }

  build() {
    Tabs() {
      TabContent() {
        ChatPage({ profileVer: this.profileVer })
      }
      .tabBar($r('app.string.tab_chat'))

      TabContent() {
        SettingsPage({
          onProfileChanged: (): void => {
            this.profileVer = this.profileVer + 1;
          }
        })
      }
      .tabBar($r('app.string.tab_settings'))

      TabContent() {
        AboutPage()
      }
      .tabBar($r('app.string.tab_about'))
    }
    .barPosition(BarPosition.End)
    .barHeight(56)
  }
}
