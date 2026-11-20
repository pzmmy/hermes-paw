import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { Msg } from '../utils/Msg';
import { LogSafe } from '../utils/LogSafe';

// viewmodel/VoiceInput.ets —— 端侧语音识别（ASR）一轮的完整生命周期
// EN: one-shot on-device ASR round (CoreSpeechKit): create -> listen ->
//     (complete | error | finish | cancel) -> shutdown.
//
// 为什么单独成文件：ChatVM 的 102,400 B 预算只剩 3 千多字节，而语音这块
// 有 8 个私有字段 + 7 个方法、且与聊天状态机几乎不交叉（只回吐 notice/error
// 和一个最终文本回调），是唯一能整块搬走还不牵动别处的部分。
//
// 生命周期（D2）：每轮一个 engine，create + shutdown，不跨轮复用。
// 幂等（D2）：ended 一次性位保证 complete 与迟到的 error 不会重复收口。

const TAG = 'VoiceInput';

/** P3-03：ASR 录音超长/超时的错误码集合。HarmonyOS on-device ASR 对超长录音
 *  返回 1002200003（及同族的时长/超时类错误）。命中则提示「录音过长」，
 *  而非笼统的「识别失败」（容易被误读成网络/Token 问题）。 */
export function isVoiceTooLongCode(code: number): boolean {
  return code === 1002200003 || code === 1002200001 || code === 1002200002;
}

/** 宿主（ChatVM）注入的两个回吐口；最终文本走 start() 的入参回调。 */
export interface VoiceHooks {
  onNotice: (msg: string) => void;
  onError: (msg: string) => void;
}

export class VoiceInput {
  /** 'idle' | 'listening'（D5：listening 时输入行换成实时文本 + 采纳/丢弃） */
  state: string = 'idle';

  private preview: string = '';
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private sessionId: string = '';
  private accum: string = '';
  private discarded: boolean = false;
  private ended: boolean = false;
  private finalCb: (text: string) => void = (text: string): void => {
  };
  private hooks: VoiceHooks;

  constructor(hooks: VoiceHooks) {
    this.hooks = hooks;
  }

  /** 实时识别文本（已结算子句 + 当前部分结果），供输入行渲染。 */
  partial(): string {
    return this.preview;
  }

  isIdle(): boolean {
    return this.state === 'idle';
  }

  /** 请求 MICROPHONE（user_grant）并开始一轮识别。 */
  async start(ctx: common.Context, onFinal: (text: string) => void): Promise<void> {
    if (this.state !== 'idle') {
      return;
    }
    this.finalCb = onFinal;
    // ohos.permission.MICROPHONE 是 user_grant：引擎开听之前必须在运行期申请
    // （权限声明在 module.json5）。
    let atMgr: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    // PermissionRequestResult 在本 SDK 里没有具名导出，按结果结构推断
    // （与 ScanVM.startScan 同一写法）。
    let grant = await atMgr.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
    if (grant.authResults.length === 0 || grant.authResults[0] !== 0) {
      this.hooks.onError(Msg.t('m_vm_mic_perm'));
      return;
    }
    let engine: speechRecognizer.SpeechRecognitionEngine | null = null;
    try {
      // online:1 = 离线模式（本机唯一可用模式，不依赖网络）。
      let extraParams: Record<string, Object> = { 'locate': 'CN', 'recognizerMode': 'short' };
      let params: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1,
        extraParams: extraParams
      };
      engine = await speechRecognizer.createEngine(params);
      this.engine = engine;
      this.accum = '';
      this.discarded = false;
      this.ended = false;
      this.preview = '';
      this.state = 'listening';
      let listener: speechRecognizer.RecognitionListener = {
        onStart: (sessionId: string, eventMessage: string): void => {
          LogSafe.i(TAG, 'ASR start session=%{public}s', sessionId);
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
          LogSafe.d(TAG, 'ASR event code=%{public}d', eventCode);
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          // 按子句回结果：isFinal = 该子句已定稿；isLast 标记本轮最后一句。
          if (result.isFinal) {
            this.accum += result.result;
          }
          this.preview = this.accum + result.result;
        },
        onComplete: (sessionId: string, eventMessage: string): void => {
          this.onEnd();
        },
        onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
          this.onErr(errorCode, errorMessage);
        }
      };
      engine.setListener(listener);
      this.sessionId = 'voice-' + Date.now().toString(36) +
        Math.floor(Math.random() * 1000000).toString(36);
      // recognitionMode:0 = 引擎自己采麦（需 MICROPHONE 权限）；
      // VAD 自动收尾（尾部静音 0.8s / 起始静音 10s / 硬上限 30s，D4）。
      let startExtra: Record<string, Object> = {
        'recognitionMode': 0,
        'vadBegin': 10000,
        'vadEnd': 800,
        'maxAudioDuration': 30000
      };
      let startParams: speechRecognizer.StartParams = {
        sessionId: this.sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, soundChannel: 1 },
        extraParams: startExtra
      };
      // 同步调用：启动失败不会走 promise，而是从监听器的 onError 冒出来
      // （例如 1002200002）。
      engine.startListening(startParams);
      LogSafe.i(TAG, 'ASR listening started');
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'startVoice failed: %{public}s', e.message);
      this.hooks.onError(Msg.t('m_vm_voice_start_fail') + e.message);
      this.state = 'idle';
      this.preview = '';
      if (engine !== null) {
        this.engine = null;
        this.release(engine);
      }
    }
  }

  /** 采纳本轮（⏹）：引擎收尾，定稿文本经 onComplete -> onEnd 送回。 */
  finish(): void {
    let engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (this.state !== 'listening' || engine === null) {
      return;
    }
    try {
      engine.finish(this.sessionId);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'ASR finish failed: %{public}s', e.message);
      this.onErr(-1, e.message);
    }
  }

  /** 丢弃本轮（✕）：取消引擎，定稿文本被丢弃（discarded 守卫投递）。 */
  cancel(): void {
    let engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    if (this.state !== 'listening' || engine === null) {
      return;
    }
    this.discarded = true;
    try {
      engine.cancel(this.sessionId);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'ASR cancel failed: %{public}s', e.message);
      // 依然要收尾：本轮已结束，文本已丢弃。
      this.onEnd();
    }
  }

  /** 一次性收口（onComplete / 错误 / 30s 上限）：投递定稿文本（未丢弃时）、
   *  复位状态、释放引擎（D2 每轮一个引擎）。 */
  private onEnd(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    if (!this.discarded) {
      let text: string = this.accum.trim();
      if (text !== '') {
        this.hooks.onNotice(Msg.t('m_vm_voice_done'));
        this.finalCb(text);
      } else {
        this.hooks.onNotice(Msg.t('m_vm_voice_empty'));
      }
    }
    this.state = 'idle';
    this.preview = '';
    this.shutdown();
  }

  /** 监听器报错（1002200002 启动 / 1002200004 收尾 / 1002200005 取消 /
   *  1002200006 忙 …），或同步抛出的 -1。 */
  private onErr(code: number, msg: string): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    if (!this.discarded) {
      if (isVoiceTooLongCode(code)) {
        this.hooks.onError(Msg.t('m_vm_voice_too_long'));
      } else {
        this.hooks.onError(Msg.t('m_vm_voice_fail_prefix') + String(code) + '）：' + msg);
      }
    }
    this.state = 'idle';
    this.preview = '';
    this.shutdown();
  }

  /** 释放本轮引擎（幂等）。 */
  private shutdown(): void {
    let engine: speechRecognizer.SpeechRecognitionEngine | null = this.engine;
    this.engine = null;
    if (engine !== null) {
      this.release(engine);
    }
  }

  /** shutdown 是同步调用；永远不让它从监听器或 catch 路径里抛出来。 */
  private release(engine: speechRecognizer.SpeechRecognitionEngine): void {
    try {
      engine.shutdown();
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'ASR shutdown failed: %{public}s', e.message);
    }
  }
}
