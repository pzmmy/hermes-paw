import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { window } from '@kit.ArkUI';
import { accentInit } from '../theme/Accent';
import { Msg } from '../utils/Msg';

const TAG: string = 'HermesPaw';

/** S1 app-lifecycle emitter ids (emitted here, consumed by ChatPage —
 *  same "constant lives on the emitting side" convention as
 *  PROFILE_CHANGED_EVENT_ID in ScanPage). 0x1001 is taken. */
export const APP_FOREGROUND_EVENT_ID: number = 0x1002;
export const APP_BACKGROUND_EVENT_ID: number = 0x1003;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogSafe.i(TAG, 'onCreate: launchReason=%{public}d', launchParam.launchReason);
    // S11: 运行时文案统一走 Msg.t(key)（与 $r() 共用同一套 string.json）
    Msg.init(this.context.resourceManager);
  }

  /** 热启动（P2-10）：M1 不解析 want，记录 reason 防后续误判「未处理」 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogSafe.i(TAG, 'onNewWant: hot launch, launchReason=%{public}d', launchParam.launchReason);
  }

  onDestroy(): void {
    LogSafe.i(TAG, 'onDestroy: app destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // A3: seed the saved accent before first paint so the UI tree already
    // reads the persisted value (cold-start semantics, like the language
    // switch). accentInit never rejects: on failure the accent stays at
    // its safe default (index 0).
    let ctx: common.UIAbilityContext = this.context as common.UIAbilityContext;
    accentInit(ctx).then((): void => {
      windowStage.loadContent('pages/Index', (err: BusinessError): void => {
        if (err.code) {
          LogSafe.e(TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        LogSafe.i(TAG, 'loadContent succeeded');
      });
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
    // S1: ChatVM resumes any in-flight run (recovery loop:
    // getRun + resubscribe with the seq gate) via 0x1002.
    let ev: emitter.InnerEvent = { eventId: APP_FOREGROUND_EVENT_ID };
    emitter.emit(ev);
  }

  onBackground(): void {
    // S1: ChatVM keeps the run, destroys the stream (timers freeze
    // with the process); resume on foreground.
    let ev: emitter.InnerEvent = { eventId: APP_BACKGROUND_EVENT_ID };
    emitter.emit(ev);
  }
}
