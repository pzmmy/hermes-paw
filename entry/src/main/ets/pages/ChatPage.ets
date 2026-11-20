// =====================================================================
// pages/ChatPage.ets — chat screen (M1: session chips, message list,
// streaming bubble, input bar; S1: step flow, approval card,
// stop-confirm, /steer interject, app-lifecycle recovery hooks)
// 中文：聊天页视图 —— 顶部单行（会话 / 当前标题 / 新对话）、消息列表、流式气泡、输入栏、审批卡、长按删除
//
// S1 UI contract (plan v2.5 §4.3/§7.4, evidence-verified):
//   step flow:  tool.started/completed pair rows inside the streaming
//     bubble (transient, not persisted)
//   approval:   card with 4 choices (once/session/always/deny) + 60s
//     display countdown (D2: the 5s status poll is the source of truth;
//     unknown kind renders a notice instead of the tool-specific text)
//   stop:       confirmed before the /stop POST (partial reply kept)
//   steer:      插话 button sends /steer into the running run
//   lifecycle:  0x1002 (foreground) -> vm.resumeFromBackground();
//     0x1003 (background) -> vm.suspendForBackground()
// =====================================================================
import { Msg } from '../utils/Msg';
import { common } from '@kit.AbilityKit';
import { emitter } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { LogSafe } from '../utils/LogSafe';
import { DbHelper } from '../store/DbHelper';
import { ChatVM } from '../viewmodel/ChatVM';
import { SettingsVM } from '../viewmodel/SettingsVM';
import { LocalMessage } from '../model/ChatMessage';
import { LocalSession } from '../model/LocalSession';
import { MergedSession } from '../viewmodel/SessionMerge';
import { SessionPanel } from './chat/SessionPanel';
import { ApprovalCard } from './chat/ApprovalCard';
import { StatusBar } from './chat/StatusBar';
import { LoginGate } from './chat/LoginGate';
import { ChatNotice } from './chat/ChatNotice';
import { ServerProfile } from '../model/Profile';
import { ApprovalControl } from '../model/Run';
import { ToolStep } from '../model/ToolStep';
import { MdBlock, MdSeg } from '../model/Markdown';
import { SessionInfo } from '../net/SessionsApi';
import { APP_FOREGROUND_EVENT_ID, APP_BACKGROUND_EVENT_ID } from '../entryability/EntryAbility';
import { accentPrimary, accentTint } from '../theme/Accent';
import { MdCache } from '../utils/MdCache';

const TAG: string = 'ChatPage';

@Component
export struct ChatPage {
  @State vm: ChatVM | null = null;
  @State inputText: string = '';
  @State bootError: string = '';
  /** S1: server sessions takeover panel (overlay on the chat screen). */
  @State showServerSessions: boolean = false;
  /** 体验-01: hide empty (message_count===0) server sessions in the panel. */
  @State hideEmpty: boolean = false;
  /** P3: 会话面板搜索关键字（空 = 不过滤）。 */
  @State sessionQuery: string = '';
  /** S2-b: the bubble whose long-press action bar is open (null = closed). */
  @State menuFor: LocalMessage | null = null;
  /** BUG-001: assistant messages whose thinking block is expanded. Keyed
   *  by the message's stable render key (createdAt) so the ForEach diff
   *  keeps the toggle state across list updates. Collapsed by default. */
  @State expandedThinking: number[] = [];
  /** Bumped by Index whenever settings changes a server profile:
   *  the chat screen must re-initialize against the new server
   *  (batch2 P0-C). */
  @Prop @Watch('onProfileVerChange') profileVer: number = 0;
  /** BUG-005 缺陷3 守卫：last profileVer we actually re-initialized for.
   *  @Prop is re-assigned (even with an unchanged value) whenever the
   *  parent re-renders, which fires @Watch on every render. Without this
   *  guard a parent re-render after a send / tab switch re-runs initChat,
   *  whose async getActiveProfile() can transiently return null and drop
   *  the live VM back to the skeleton mid-conversation. Only a genuine
   *  version bump re-initializes. */
  private lastProfileVer: number = 0;
  /** BUG-005 fix2: UI version counter. The VM bumps this via onUiChange on
   *  every user-visible state mutation (messages / busy / streamText / steps /
   *  approval). @State tracks THIS field, so reading it in build() forces a
   *  re-render of the message list and conditionals even though the VM itself
   *  is a plain (non-@Observed) class whose inner fields @State can't see. */
  @State uiVersion: number = 0;
  /** A1: 1s tick driving the elapsed-seconds display while a run is in
   *  flight; bumps only while busy so the UI is idle otherwise. */
  @State tick: number = 0;
  /** E1: true on first launch (no active profile) — drives the onboarding
   *  card instead of the bare unconfigured text. */
  @State needOnboard: boolean = false;
  /** A1: self-scheduling setTimeout id for the elapsed tick (-1 = off). */
  private elapsedTimerId: number = -1;
  /** §R10-1: 骨架屏呼吸动画的当前不透明度（0.4↔0.8，1200ms 一周期）。 */
  @State skeletonOpacity: number = 0.4;
  /** §R10-1: 骨架屏呼吸动画 ticker（页面存活期常驻，仅在 busy 时改值）。 */
  private skeletonTimerId: number = -1;
  private scroller: Scroller = new Scroller();
  private ctxRef: common.UIAbilityContext | null = null;
  private dbRef: DbHelper | null = null;
  /** S10a (§R12): render-side Markdown parse cache (length key + LRU 8 +
   *  500ms throttle). Dropped on session switch / new session / delete. */
  private mdCache: MdCache = new MdCache();

  aboutToAppear(): void {
    // getContext deprecated since API 18; getHostContext is the official
    // replacement (batch2-r4 P1-01). UIAbility page: host context is UIAbilityContext.
    let ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.ctxRef = ctx;
    this.bootstrap(ctx);
    // A1: start the 1s elapsed tick (self-scheduling; cleared in
    // aboutToDisappear).
    this.startElapsedTick();
    // §R10-1: start the skeleton pulse (only mutates while a run is busy).
    this.startSkeletonPulse();
    // S1: app lifecycle (EntryAbility 0x1002/0x1003) — recover or
    // suspend the in-flight run on the owning VM.
    let fg: emitter.InnerEvent = { eventId: APP_FOREGROUND_EVENT_ID };
    emitter.on(fg, (data: emitter.EventData): void => {
      if (this.vm !== null) {
        this.vm.resumeFromBackground();
      }
    });
    let bg: emitter.InnerEvent = { eventId: APP_BACKGROUND_EVENT_ID };
    emitter.on(bg, (data: emitter.EventData): void => {
      if (this.vm !== null) {
        this.vm.suspendForBackground();
      }
    });
  }

  aboutToDisappear(): void {
    // A1: stop the elapsed tick.
    this.stopElapsedTick();
    // §R10-1: stop the skeleton pulse.
    this.stopSkeletonPulse();
    // S2-c: never leave an ASR round (and its mic capture) behind.
    if (this.vm !== null) {
      this.vm.cancelVoice();
    }
    emitter.off(APP_FOREGROUND_EVENT_ID);
    emitter.off(APP_BACKGROUND_EVENT_ID);
  }

  private bootstrap(ctx: common.UIAbilityContext): void {
    DbHelper.get(ctx).then((db: DbHelper) => {
      this.dbRef = db;
      this.initChat(ctx, db);
    }).catch((err: Error) => {
      // 留白-01 收口：启动错误文案走 i18n（占位符 %s = 错误消息）。
      try {
        this.bootError = ctx.resourceManager.getStringSync($r('app.string.db_init_failed_fmt'), err.message);
      } catch (e2) {
        this.bootError = Msg.t('m_about_db_init_fail') + err.message;
      }
    });
  }

  /** (Re)create the ChatVM against the currently active server.
   *  Shared by first boot and profile changes (batch2 P0-C). */
  private initChat(ctx: common.UIAbilityContext, db: DbHelper): void {
    let svm: SettingsVM = new SettingsVM(ctx, db);
    svm.load().then(() => {
      let prof: ServerProfile | null = svm.getActiveProfile();
      if (prof === null) {
        // BUG-005 fix3: a re-init triggered by a parent re-render can hit
        // getActiveProfile() before the store settles, transiently
        // returning null. If we already hold a live VM (mid-conversation),
        // keep it instead of dropping back to the skeleton — only a true
        // first-boot / explicit unconfigure should null the VM.
        if (this.vm !== null) {
          LogSafe.w(TAG, 'initChat: profile null but VM alive, keeping it');
          return;
        }
        // Explicit unconfigured state (batch2-r2 P0-C): no active or
        // not-yet-configured profile. Show a clear notice instead of
        // silently building a VM around an empty ServerProfile.
        this.vm = null;
        // 留白-01 收口：启动错误文案走 i18n（静态句，无占位符）。
        try {
          this.bootError = ctx.resourceManager.getStringSync($r('app.string.boot_error_no_server'));
        } catch (e2) {
          this.bootError = Msg.t('m_chat_no_server');
        }
        this.needOnboard = true;
        return;
      }
      let vm: ChatVM = new ChatVM(ctx, db, prof);
      // BUG-005 fix2: wire the VM's UI-change hook to bump this page's
      // @State uiVersion. Without it, @State vm (a plain class) never
      // re-renders on messages/busy/streamText changes (BUG-005 defect 2).
      let page: ChatPage = this;
      vm.onUiChange = (): void => {
        page.uiVersion = page.uiVersion + 1;
      };
      this.bootError = '';
      this.needOnboard = false;
      this.vm = vm;
      vm.connect().then(() => {
        if (vm.ready) {
          vm.listLocalSessions().then(() => {
            // state already updated on vm
          }).catch((err: Error): void => {
            LogSafe.w(TAG, 'listLocalSessions failed: %{public}s', err.message);
          });
        }
      }).catch((err: Error): void => {
        LogSafe.w(TAG, 'connect failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      // 留白-01 收口：启动错误文案走 i18n（占位符 %s = 错误消息）。
      try {
        this.bootError = ctx.resourceManager.getStringSync($r('app.string.init_failed_fmt'), err.message);
      } catch (e2) {
        this.bootError = Msg.t('m_chat_init_fail') + err.message;
      }
    });
  }

  /** @Watch(profileVer): a server profile changed in settings — stop
   *  any in-flight stream and re-initialize against the new server
   *  (batch2 P0-C). */
  private onProfileVerChange(): void {
    if (this.profileVer === 0) {
      return;
    }
    // BUG-005 fix3: @Prop fires @Watch on every parent re-render even when
    // the value is unchanged. Only a genuine version change should re-init,
    // or a post-send / tab-switch re-render drops the live VM to skeleton.
    if (this.profileVer === this.lastProfileVer) {
      return;
    }
    this.lastProfileVer = this.profileVer;
    let ctx: common.UIAbilityContext | null = this.ctxRef;
    let db: DbHelper | null = this.dbRef;
    if (ctx === null || db === null) {
      return;
    }
    let old: ChatVM | null = this.vm;
    if (old !== null) {
      old.stopStream();
      // S2-c: a re-init replaces the VM; end any live ASR round on the
      // old one (mic capture cannot outlive its owner).
      old.cancelVoice();
    }
    LogSafe.i(TAG, 'profile changed (v%{public}d), re-initializing', this.profileVer);
    this.initChat(ctx, db);
  }

  private v(): ChatVM {
    return this.vm as ChatVM;
  }

  private autoScroll(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private onNewSession(): void {
    if (this.vm !== null && !this.vm.busy) {
      this.vm.newSession();
      // S10a: a new conversation must never inherit old cached blocks.
      this.mdCache.clear();
    }
  }

  private onOpenSession(pk: string): void {
    if (this.vm !== null && !this.vm.busy && pk !== this.vm.activePk) {
      this.vm.openSession(pk);
      // S10a: switching conversations invalidates every cached parse.
      this.mdCache.clear();
      this.autoScroll();
    }
  }

  private onSend(): void {
    let v: ChatVM | null = this.vm;
    if (v === null || v.busy) {
      return;
    }
    // P2: 未登录时数据面关闭（设计文档 §9）——闸门覆盖层已挡住输入，
    // 此处防御性拦截。
    if (v.authMode === 'loggedOut') {
      return;
    }
    let t: string = this.inputText.trim();
    // S2-a: image-only sends are allowed (the attachment row carries
    // the payload).
    if (t === '' && v.pendingImages.length === 0) {
      return;
    }
    this.inputText = '';
    let uris: string[] = v.pendingImages.slice();
    v.sendMessage(t, uris);
    this.autoScroll();
  }

  /** S2-a: open the album picker (the VM guards ready/busy/limits). */
  private onPickImage(): void {
    let v: ChatVM | null = this.vm;
    if (v === null || v.busy) {
      return;
    }
    v.pickImages();
  }

  /** S2-a: remove one pending attachment chip. */
  private onRemoveImage(uri: string): void {
    let v: ChatVM | null = this.vm;
    if (v === null || v.busy) {
      return;
    }
    v.removePendingImage(uri);
  }

  /** S2-c: 🎤 — start one on-device ASR round (permission + engine live
   *  in the VM); the final text fills the input field (D3: the user
   *  confirms the send). */
  private onMicTap(): void {
    let v: ChatVM | null = this.vm;
    if (v === null || v.busy || v.voiceState !== 'idle') {
      return;
    }
    v.startVoice((text: string): void => {
      this.inputText = this.inputText === '' ? text : text + ' ' + this.inputText;
    });
  }

  /** S2-c: ⏹ — adopt: the engine finalizes; the text arrives via the
   *  onFinal callback (onComplete). */
  private onVoiceFinish(): void {
    let v: ChatVM | null = this.vm;
    if (v !== null) {
      v.finishVoice();
    }
  }

  /** S2-c: ✕ — discard the round. */
  private onVoiceCancel(): void {
    let v: ChatVM | null = this.vm;
    if (v !== null) {
      v.cancelVoice();
    }
  }

  /** S1: /steer — interject into the running run without stopping it. */
  private onSteer(): void {
    let v: ChatVM | null = this.vm;
    if (v === null || !v.busy) {
      return;
    }
    let t: string = this.inputText.trim();
    if (t === '') {
      return;
    }
    this.inputText = '';
    v.sendSteer(t);
    this.autoScroll();
  }

  /** S1: stop is confirmed first (plan §4.3); the VM then posts
   *  /stop and keeps the partial reply. */
  private onStopRequested(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.stop_dialog_title'),
      message: $r('app.string.stop_dialog_msg'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel'),
        fontColor: '#757575',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: $r('app.string.btn_stop'),
        fontColor: '#E53935',
        action: (): void => {
          if (this.vm !== null) {
            this.vm.stopStream();
          }
        }
      }
    });
  }

  /** S1: approval-card command text via accessor — build() forbids local
   *  statements (10905209) and per-access null narrowing on the this.v()
   *  chain is not retained; the method layer narrows via local lets. */
  private approvalCommand(): string {
    let vm: ChatVM | null = this.v();
    if (vm === null) {
      return '';
    }
    let pa: ApprovalControl | null = vm.pendingApproval;
    if (pa === null) {
      return '';
    }
    return pa.command;
  }

  private approvalDescription(): string {
    let vm: ChatVM | null = this.v();
    if (vm === null) {
      return '';
    }
    let pa: ApprovalControl | null = vm.pendingApproval;
    if (pa === null) {
      return '';
    }
    return pa.description;
  }

  /** S1: one of the four approval choices (VM validates + posts). */
  private onApproval(choice: string): void {
    if (this.vm !== null) {
      this.vm.submitApproval(choice);
    }
  }

  /** S10a: stable per-bubble cache key for mdView. Uses the same three
   *  components as the message ForEach render key (id/serverMsgId/createdAt)
   *  — createdAt ALONE is not unique: a server refetch stamps every row of
   *  the batch with one `now`, so two same-length replies would share a
   *  cache key. These three never change for a given message across frames,
   *  and are never reused by a different message. */
  private mdKeyOf(m: LocalMessage): string {
    return String(m.id) + '_' + String(m.serverMsgId) + '_' + String(m.createdAt);
  }

  /** S2-b: long-press a bubble -> open the bottom action bar. */
  private onBubbleLongPress(m: LocalMessage): void {
    this.menuFor = m;
  }

  private closeBubbleMenu(): void {
    this.menuFor = null;
  }

  // ============ P4⑦: lightweight Markdown (model/Markdown.ets) ============
  /** Parse assistant text into Markdown blocks (streaming-tolerant).
   *  S10a: goes through MdCache — same callerKey + same text.length is a
   *  cache hit with zero parsing; a length change inside the 500ms
   *  throttle window returns the previous blocks (utils/MdCache.ets). */
  mdParse(content: string, key: string): MdBlock[] {
    return this.mdCache.get(key, content);
  }

  /** P4⑦: render Markdown blocks — heading / image / table / para (bold+link).
   *  Called from build() (ArkUI build() accepts method calls, no local vars).
   *  S10a: parsing is cached per (key, text.length); `key` must be stable
   *  for the same bubble across frames (message createdAt / '__stream__'),
   *  otherwise the cache misses and the old O(n²) re-parse path returns. */
  @Builder
  mdView(content: string, key: string) {
    Column() {
      ForEach(this.mdParse(content, key), (b: MdBlock) => {
        if (b.type === 'heading') {
          Text(b.text)
            .fontSize(b.level <= 1 ? 18 : (b.level === 2 ? 16 : 14))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .margin({ top: 6, bottom: 2 })
        } else if (b.type === 'image') {
          Image(b.url)
            .width('100%')
            .objectFit(ImageFit.Contain)
            .borderRadius(8)
            .margin({ top: 4, bottom: 4 })
        } else if (b.type === 'table') {
          Scroll() {
            Column() {
              ForEach(b.rows, (row: string[]) => {
                Row() {
                  ForEach(row, (cell: string) => {
                    Text(cell)
                      .fontSize(12)
                      .fontColor($r('app.color.text_primary'))
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .border({ width: 0.5, color: '#DDDDDD' })
                      .constraintSize({ minWidth: 56 })
                  }, (cell: string, ci: number): string => 'c' + ci + '_' + cell)
                }
              }, (row: string[], ri: number): string => 'r' + ri)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        } else {
          // para: Text with inline Spans (bold + link) via ForEach
          Text() {
            ForEach(b.segs, (seg: MdSeg) => {
              Span(seg.text)
                .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(seg.link !== '' ? accentPrimary() : $r('app.color.text_primary'))
            }, (seg: MdSeg, si: number): string => 's' + si + '_' + seg.text)
          }
          .fontSize(14)
        }
      }, (b: MdBlock, bi: number): string =>
        'b' + bi + '_' + b.type + '_' + String(b.text.length + b.rows.length + b.url.length))
    }
    .width('100%')
  }

  /** BUG-001: is the thinking block of this assistant message expanded?
   *  Keyed by createdAt (matches the ForEach render key). */
  private isThinkingExpanded(m: LocalMessage): boolean {
    return this.expandedThinking.indexOf(m.createdAt) >= 0;
  }

  /** BUG-001: toggle the thinking block of an assistant message. Replaces
   *  the array reference so the ForEach re-diffs (same pattern as
   *  LocalMessage.content updates). */
  private toggleThinking(m: LocalMessage): void {
    let arr: number[] = this.expandedThinking.slice();
    let idx: number = arr.indexOf(m.createdAt);
    if (idx >= 0) {
      arr.splice(idx, 1);
    } else {
      arr.push(m.createdAt);
    }
    this.expandedThinking = arr;
  }

  /** S2-b accessors: build() does not retain per-access null narrowing on
   *  @State properties (same pattern as the S1 approval card accessors). */
  private menuHasText(): boolean {
    let m: LocalMessage | null = this.menuFor;
    return m !== null && m.content !== '';
  }

  private menuIsUser(): boolean {
    let m: LocalMessage | null = this.menuFor;
    return m !== null && m.role === 'user';
  }

  /** S2-b: quote-context accessors (build() null-narrowing, same pattern
   *  as the menu accessors). */
  private hasQuote(): boolean {
    let v: ChatVM | null = this.vm;
    return v !== null && v.quoteContext !== null;
  }

  private quoteText(): string {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return '';
    }
    let q: LocalMessage | null = v.quoteContext;
    if (q === null) {
      return '';
    }
    let c: string = q.content;
    if (c.length > 40) {
      c = c.substring(0, 40) + '…';
    }
    return c;
  }

  /** S2-b: dismiss the "回复中" bar (the ✕). */
  private onClearQuote(): void {
    let v: ChatVM | null = this.vm;
    if (v !== null) {
      v.clearQuote();
    }
  }

  /** S2-b: copy the bubble text (VM handles pasteboard + notice). */
  private onMenuCopy(): void {
    let m: LocalMessage | null = this.menuFor;
    if (m !== null && this.vm !== null) {
      this.vm.copyText(m.content);
    }
    this.closeBubbleMenu();
  }

  /** S2-b: resend a user bubble (VM guards role/busy/ready). */
  private onMenuResend(): void {
    let m: LocalMessage | null = this.menuFor;
    if (m !== null && this.vm !== null) {
      this.vm.resendMessage(m);
    }
    this.closeBubbleMenu();
  }

  /** S2-b: 引用 — set the quote context (VM prepends it to the next send). */
  private onMenuQuote(): void {
    let m: LocalMessage | null = this.menuFor;
    if (m !== null && this.vm !== null) {
      this.vm.quoteMessage(m);
    }
    this.closeBubbleMenu();
  }

  /** S2-b: 删除 — confirm, then remove the message (VM: list + DB row). */
  private onMenuDelete(): void {
    let m: LocalMessage | null = this.menuFor;
    let vm: ChatVM | null = this.vm;
    this.closeBubbleMenu();
    if (m === null || vm === null) {
      return;
    }
    let target: LocalMessage = m;
    let vmRef: ChatVM = vm;
    AlertDialog.show({
      title: $r('app.string.delete_msg_title'),
      message: $r('app.string.delete_msg_confirm'),
      primaryButton: {
        value: $r('app.string.cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.danger'),
        action: () => {
          vmRef.deleteMessage(target);
          // S10a: the deleted bubble's key/length may be reused by another
          // message later — clear rather than leave a stale block behind.
          this.mdCache.clear();
        }
      }
    });
  }

  /** S2-b: stop from the menu — the S1 confirm dialog is reused. */
  private onMenuStop(): void {
    this.closeBubbleMenu();
    this.onStopRequested();
  }

  /** S2-b: approve from the menu — the S1 four-choice dialog on the
   *  same VM submit path as the inline card. The card is always visible
   *  below the list; the menu is the quick path from a bubble. */
  private onMenuApprove(): void {
    this.closeBubbleMenu();
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return;
    }
    let pa: ApprovalControl | null = v.pendingApproval;
    if (pa === null) {
      return;
    }
    let first: string = (pa.description !== '' ? pa.description : Msg.t('m_chat_approval_needed')) + Msg.t('m_chat_approval_once');
    // Documented API shape (ArkUI promptAction): showActionMenu takes
    // ActionMenuOptions { buttons: Button[] } with Button = { text, color }
    // (color mandatory); the response carries index; no { value, id }
    // array form exists. PromptAction is reached via getPromptAction
    // (API 11+), but the PromptAction type is not exported by name in
    // this SDK — infer the returned object type (same pattern as
    // `grant` in ChatVM.startVoice).
    let prompt = this.getUIContext().getPromptAction();
    prompt.showActionMenu({
      buttons: [
        { text: first, color: '#212121' },
        { text: $r('app.string.appr_session_approve'), color: '#212121' },
        { text: $r('app.string.appr_always_approve'), color: '#212121' },
        { text: $r('app.string.appr_deny'), color: '#212121' }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse): void => {
      if (res.index === 0) {
        this.onApproval('once');
      } else if (res.index === 1) {
        this.onApproval('session');
      } else if (res.index === 2) {
        this.onApproval('always');
      } else {
        this.onApproval('deny');
      }
    }).catch((err: Error): void => {
      LogSafe.w(TAG, 'approval menu closed: %{public}s', err.message);
    });
  }

  private stepLabel(st: ToolStep): string {
    let base: string = st.tool === '' ? 'tool' : st.tool;
    if (st.state === 'running') {
      return base + (st.preview !== '' ? ' ' + st.preview : '');
    }
    let dur: string = st.durationSec >= 0 ? ' ' + String(st.durationSec) + 's' : '';
    return base + dur + (st.preview !== '' ? ' ' + st.preview : '');
  }

  private approvalStatusText(): string {
    let pa: ApprovalControl | null = this.v().pendingApproval;
    if (pa === null) {
      return '';
    }
    try {
      let context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (pa.kind !== 'tool_approval') {
        return context.resourceManager.getStringSync($r('app.string.approval_type_fmt'), pa.kind);
      }
      return context.resourceManager.getStringSync($r('app.string.approval_countdown_fmt'), String(this.v().approvalCountdownSec));
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'approvalStatusText fmt failed: %{public}s', e.message);
      return '';
    }
  }

  /** S9a-2b：长按会话行 → 确认后删除（服务端 + 本机记录）。 */
  private onSessionLongPress(m: MergedSession): void {
    let vmRef: ChatVM | null = this.vm;
    if (vmRef === null) {
      return;
    }
    let vm2: ChatVM = vmRef;
    let name: string = m.title !== '' ? m.title : Msg.t('m_chat_untitled_session');
    let pk: string = m.pk;
    let sid: string = m.sessionId;
    AlertDialog.show({
      title: Msg.t('m_chat_delete_title'),
      message: '「' + name + Msg.t('m_chat_delete_body_suffix'),
      primaryButton: {
        value: $r('app.string.cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.danger'),
        action: () => {
          vm2.deleteSession(pk, sid);
          this.showServerSessions = true;
        }
      }
    });
  }

  /** S1: open the server sessions takeover panel + refresh the list. */
  private openServerSessions(): void {
    if (this.vm === null) {
      return;
    }
    this.showServerSessions = true;
    this.vm.listServerSessions();
  }

  /** S1: 接手 — take over the server session, close the panel. */
  private onTakeover(id: string, title: string): void {
    if (this.vm === null || this.vm.busy) {
      return;
    }
    this.showServerSessions = false;
    this.vm.takeoverSession(id, title);
    // S10a: takeover replaces the whole message list — drop cached blocks.
    this.mdCache.clear();
    this.autoScroll();
  }

  /** S9a：顶部单行只显示当前会话标题；没有当前行时给占位文案。 */
  private activeTitle(): string {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return Msg.t('m_chat_current_session');
    }
    for (let i: number = 0; i < v.sessions.length; i++) {
      if (v.sessions[i].pk === v.activePk) {
        let t: string = v.sessions[i].title;
        return t !== '' ? t : Msg.t('m_chat_current_session');
      }
    }
    return Msg.t('m_chat_current_session');
  }

  /** Panel row meta: '66 条 · 03-15 14:22'. */
  private sessionRowMeta(s: SessionInfo): string {
    let meta: string = this.fmtCount(s.message_count);
    if (s.last_active > 0) {
      meta += ' · ' + this.sessionTime(s.last_active);
    }
    return meta;
  }

  /** i18n: localize the "{n} 条" count. resourceManager resolves the
   *  active-locale string; falls back to the raw count on any error
   *  (keeps the build safe if the context is unavailable). */
  private fmtCount(n: number): string {
    try {
      let context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.resourceManager.getStringSync($r('app.string.session_count_fmt'), String(n));
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'fmtCount failed: %{public}s', e.message);
      return String(n) + Msg.t('m_chat_count_suffix');
    }
  }

  /** unix seconds (float, R-05 evidence) -> 'MM-DD HH:mm'. */
  private sessionTime(tsSec: number): string {
    let d: Date = new Date(Math.floor(tsSec) * 1000);
    let mm: number = d.getMonth() + 1;
    let dd: number = d.getDate();
    let hh: number = d.getHours();
    let mi: number = d.getMinutes();
    return String(mm).padStart(2, '0') + '-' + String(dd).padStart(2, '0') + ' ' +
      String(hh).padStart(2, '0') + ':' + String(mi).padStart(2, '0');
  }

  /** 体验-01: how many server sessions are empty (message_count===0). */
  private emptySessionCount(): number {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return 0;
    }
    let n: number = 0;
    for (let i: number = 0; i < v.serverSessions.length; i++) {
      if (v.serverSessions[i].message_count === 0) {
        n++;
      }
    }
    return n;
  }

  /** A1: whole-seconds elapsed since the current run started (0 = none).
   *  P1 修（实测：等待期恒为 0 秒）：不再按 runStartedAt 现算，改读 VM 的
   *  elapsedSec —— 由 startBaselinePoll 起的 1s setInterval 推进。 */
  private runElapsedSec(): number {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return 0;
    }
    return v.elapsedSec;
  }

  /** §R10-1: 骨架屏呼吸动画（0.4↔0.8，周期 1200ms；无新颜色/资源键）。
   *  页面存活期常驻，仅在 busy（等待首字）时才会被看到。 */
  private startSkeletonPulse(): void {
    let page: ChatPage = this;
    this.skeletonTimerId = setInterval((): void => {
      if (page.vm === null || !page.vm.busy) {
        return;
      }
      let next: number = page.skeletonOpacity >= 0.8 ? 0.4 : 0.8;
      page.getUIContext().animateTo({ duration: 600, curve: Curve.EaseInOut }, (): void => {
        page.skeletonOpacity = next;
      });
    }, 1200);
  }

  private stopSkeletonPulse(): void {
    if (this.skeletonTimerId !== -1) {
      clearInterval(this.skeletonTimerId);
      this.skeletonTimerId = -1;
    }
  }

  /** §R10-1：首字未到时的骨架屏显示条件（有内容立刻让位给真实气泡）。 */
  private showThinkingSkeleton(): boolean {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return false;
    }
    return v.busy && v.streamText === '' && v.steps.length === 0;
  }

  /** A1: cycling dot indicator (· / ·· / ···) driven by the 1s tick. */
  private runDots(): string {
    let arr: string[] = ['·', '··', '···'];
    return arr[this.tick % 3];
  }

  /** A1: start the 1s elapsed tick (self-scheduling setTimeout — codebase
   *  idiom, S3-b). Bumps `tick` only while a run is in flight — plus the
   *  short window after a run closes (S6c: the 3s 「已收到」line expires by
   *  time difference, so it needs one repaint to disappear). */
  private startElapsedTick(): void {
    let step: () => void = (): void => {
      if (this.tickWindowOpen()) {
        this.tick = this.tick + 1;
      }
      this.elapsedTimerId = setTimeout(step, 1000);
    };
    this.elapsedTimerId = setTimeout(step, 1000);
  }

  /** S6c: 收口后 5 秒内复用既有 1s ticker 重绘（>3 秒展示窗口，多走两拍只为
   *  到期后刷掉提示）。不新增定时器。 */
  private tickWindowOpen(): boolean {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return false;
    }
    if (v.busy) {
      return true;
    }
    if (v.justFinishedMs <= 0) {
      return false;
    }
    return Date.now() - v.justFinishedMs < 5000;
  }

  /** S6c: 收口后 3 秒内显示「已收到 N 字」（靠时间差判过期，无定时器清理）。 */
  private justFinishedVisible(): boolean {
    let v: ChatVM | null = this.vm;
    if (v === null || v.busy || v.justFinishedMs <= 0 || v.justFinishedChars <= 0) {
      return false;
    }
    return Date.now() - v.justFinishedMs < 3000;
  }

  /** S6c: 等待期三态提示（判定顺序即优先级，不可调换）：
   *  ① 刚收口（3s 内）→「已收到 N 字 · 用时 X.X 秒」
   *  ② busy 且有增量  →「正在接收… N 字 · 已等待 N 秒」
   *  ③ busy 无增量    →「结果整段生成中 · 已等待 N 秒」
   *  ④ 空闲           → 空 */
  private statusBarText(): string {
    let v: ChatVM | null = this.vm;
    if (v === null) {
      return '';
    }
    if (this.justFinishedVisible()) {
      let totalMs: number = v.runStartedAt > 0 ? v.justFinishedMs - v.runStartedAt : 0;
      if (totalMs < 0) {
        totalMs = 0;
      }
      return Msg.t('m_chat_received_prefix') + String(v.justFinishedChars) + Msg.t('m_chat_chars_took') +
        (totalMs / 1000).toFixed(1) + Msg.t('m_chat_seconds');
    }
    if (v.busy) {
      if (v.streamText.length > 0) {
        return Msg.t('m_chat_receiving') + String(v.streamText.length) + Msg.t('m_chat_chars_waited') +
          String(this.runElapsedSec()) + Msg.t('m_chat_seconds');
      }
      return Msg.t('m_chat_generating_wait') + String(this.runElapsedSec()) + Msg.t('m_chat_seconds');
    }
    return '';
  }

  /** S6c: epoch ms（兼容 unix 秒）-> 'HH:mm:ss'（24 小时制）。 */
  private clockTime(ts: number): string {
    let ms: number = ts;
    if (ms > 0 && ms < 1000000000000) {
      ms = ms * 1000;
    }
    if (ms <= 0) {
      return '--:--:--';
    }
    let d: Date = new Date(ms);
    return String(d.getHours()).padStart(2, '0') + ':' +
      String(d.getMinutes()).padStart(2, '0') + ':' +
      String(d.getSeconds()).padStart(2, '0');
  }

  /** S6c: 气泡小字——用户「{HH:mm:ss} 发出」；助手「{HH:mm:ss} 收」+ 本轮
   *  用时 + 首字耗时。历史消息 elapsedMs<0（DB 无此列，刻意不迁移）只显时间。 */
  private bubbleMeta(m: LocalMessage): string {
    let isUser: boolean = m.role === 'user';
    // 时刻源按约定：用户 —— timestamp，助手 —— createdAt（本轮两者同一 now）。
    let ts: number = isUser ? m.timestamp : m.createdAt;
    if (ts <= 0) {
      ts = isUser ? m.createdAt : m.timestamp;
    }
    let head: string = this.clockTime(ts) + (isUser ? Msg.t('m_chat_sent') : Msg.t('m_chat_recv'));
    if (isUser) {
      return head;
    }
    if (m.elapsedMs >= 0) {
      head += Msg.t('m_chat_took') + (m.elapsedMs / 1000).toFixed(1) + Msg.t('m_chat_seconds');
      if (m.firstDeltaMs > 0) {
        head += Msg.t('m_chat_first_delta') + (m.firstDeltaMs / 1000).toFixed(1) + Msg.t('m_chat_seconds');
      }
    }
    return head;
  }

  private stopElapsedTick(): void {
    if (this.elapsedTimerId !== -1) {
      clearTimeout(this.elapsedTimerId);
      this.elapsedTimerId = -1;
    }
  }

  /** E1: first-launch onboarding — primary path: paste the config string
   *  (fastest; opens the scan page with the paste field revealed via the
   *  pasteFirst router param). */
  private gotoOnboardPaste(): void {
    let params: Record<string, string> = {};
    params['pasteFirst'] = 'true';
    router.pushUrl({ url: 'pages/ScanPage', params: params });
  }

  /** E1: first-launch onboarding — delegate path: let Hermes generate the
   *  config (the guided OnboardPage flow). */
  private gotoOnboardDelegate(): void {
    router.pushUrl({ url: 'pages/OnboardPage' });
  }

  /** A2: error bar 连接测试 — jump to Settings (the one-tap diagnose
   *  lives there, same endpoint + token). */
  private gotoSettingsDiagnose(): void {
    router.pushUrl({ url: 'pages/SettingsPage' });
  }

  /** 提示条的三个动作（U1/U2/A2、E3）：VM 是普通类，收窄放在方法层——
   *  build() 里只允许组件语法（10905209），闭包内联判断易被 ArkTS 拒绝。 */
  private onNoticeRetry(): void {
    let m: ChatVM | null = this.vm;
    if (m !== null && !m.busy) {
      // P4⑤: retry the last message (or reconnect if none sent).
      m.retryLastError();
    }
  }

  private onNoticeClearSuccess(): void {
    let m: ChatVM | null = this.vm;
    if (m !== null) {
      m.clearSuccess();
    }
  }

  private onNoticeClearNotice(): void {
    let m: ChatVM | null = this.vm;
    if (m !== null) {
      m.clearNotice();
    }
  }

  /** P2: 打开登录页（设计文档 §9 数据面闸门）。 */
  private gotoLogin(): void {
    router.pushUrl({ url: 'pages/LoginPage' });
  }

  /** P1+P3：面板可见行。
   *  ① 空会话（messageCount === 0）本地/服务端同口径：默认隐藏，hideEmpty 打开时显示；
   *  ② sessionQuery 非空时按标题/预览做不区分大小写的子串过滤。 */
  private visibleRows(): MergedSession[] {
    let all: MergedSession[] = this.v().mergedSessions();
    let kw: string = this.sessionQuery.trim().toLowerCase();
    let out: MergedSession[] = [];
    for (let i: number = 0; i < all.length; i++) {
      let m: MergedSession = all[i];
      if (m.messageCount === 0 && !this.hideEmpty) {
        continue;
      }
      if (kw !== '') {
        let hit: boolean = m.title.toLowerCase().indexOf(kw) >= 0
          || m.preview.toLowerCase().indexOf(kw) >= 0;
        if (!hit) {
          continue;
        }
      }
      out.push(m);
    }
    return out;
  }

  build() {
    Stack() {
    Column() {
      if (this.vm === null) {
        Column() {
          if (this.needOnboard) {
            // E1: first-launch onboarding card (paste = primary path).
            Column() {
              Text('🐾')
                .fontSize(40)
                .margin({ bottom: 12 })
              Text($r('app.string.onb_welcome'))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .margin({ bottom: 8 })
              Text($r('app.string.onb_sub'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .margin({ bottom: 20 })
              Button($r('app.string.onb_paste'))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .height(44)
                .backgroundColor(accentPrimary())
                .fontColor($r('app.color.text_inverse'))
                .borderRadius(8)
                .width('100%')
                .margin({ bottom: 10 })
                .onClick(() => {
                  this.gotoOnboardPaste();
                })
              Button($r('app.string.onb_delegate'))
                .fontSize(13)
                .height(40)
                .backgroundColor($r('app.color.success_soft'))
                .fontColor($r('app.color.success'))
                .borderRadius(8)
                .width('100%')
                .onClick(() => {
                  this.gotoOnboardDelegate();
                })
            }
            .padding(24)
            .width('85%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Center)
          } else if (this.bootError !== '') {
            Text(this.bootError)
              .fontSize(14)
              .fontColor($r('app.color.danger'))
          } else {
            // A5: loading skeleton (gray placeholder bars) while the VM
            // boots, instead of a bare "加载中…".
            Column() {
              Row() {
                Column().width('40%').height(12).borderRadius(6).backgroundColor($r('app.color.divider'))
              }
              .width('80%')
              .margin({ bottom: 16 })
              Row() {
                Column().width('60%').height(12).borderRadius(6).backgroundColor($r('app.color.divider'))
              }
              .width('80%')
              .margin({ bottom: 16 })
              Row() {
                Column().width('50%').height(12).borderRadius(6).backgroundColor($r('app.color.divider'))
              }
              .width('80%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 三段横幅（错误 / 成功 / 提示）已搬到 pages/chat/ChatNotice.ets。
        // 互斥优先级仍是 错误 > 成功 > 提示；互动全部走回调，busy 判断在方法层。
        ChatNotice({
          errorText: this.v().error,
          successText: this.v().success,
          noticeText: this.v().notice,
          onRetry: (): void => {
            this.onNoticeRetry();
          },
          onTestConn: (): void => {
            this.gotoSettingsDiagnose();
          },
          onClearSuccess: (): void => {
            this.onNoticeClearSuccess();
          },
          onClearNotice: (): void => {
            this.onNoticeClearNotice();
          }
        })

        // S9a-2a：顶部只留一行 —— [≡ 会话] 当前标题 [＋ 新对话]。
        // 旧的一排会话 pill 撤掉（会话多了横向滑不动，且长标题会把 pill 撑爆）；
        // 切换统一走面板（面板已是本地+服务端合并列表）。
        Row() {
          Text(Msg.t('m_chat_list_button'))
            .fontSize(13)
            .fontColor(accentPrimary())
            .padding({ left: 2, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.openServerSessions();
            })
          Text(this.activeTitle())
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ left: 6, right: 6 })
          Text(Msg.t('m_chat_new_button'))
            .fontSize(13)
            .fontColor(accentPrimary())
            .padding({ left: 8, right: 2, top: 4, bottom: 4 })
            .onClick(() => {
              this.onNewSession();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        // 保留原 uiVersion 依赖（旧 pill 行的同一目的）：让 VM onUiChange
        // 能重跑整个 chat 分支。opacity(1) 是视觉空操作。
        .opacity(this.uiVersion >= 0 ? 1 : 1)

        // A1/S6c: 等待期三态状态条已搬到 pages/chat/StatusBar.ets。
        // 这里只判断要不要创建（读 tick @State，让收口提示的 3 秒窗口到期后
        // 重绘刷掉），以及把父页算好的文字、忙碌位、动画点传进去。
        if (this.tick >= 0 && this.statusBarText() !== '') {
          StatusBar({
            text: this.statusBarText(),
            busy: this.v().busy,
            dots: this.runDots()
          })
        }

        List({ scroller: this.scroller }) {
          ForEach(this.v().messages, (m: LocalMessage) => {
            ListItem() {
              if (m.role === 'system') {
                // P5: system bubble (slash-command feedback) — centered,
                // small, gray; distinct from user/assistant bubbles.
                Text(m.content)
                  .fontSize(12)
                  .fontColor($r('app.color.text_hint'))
                  .padding({ top: 4, bottom: 4, left: 12, right: 12 })
                  .borderRadius(10)
                  .backgroundColor($r('app.color.bg_subtle'))
                  .alignSelf(ItemAlign.Center)
                  .margin({ top: 6, bottom: 6 })
              } else if (m.role === 'user' && m.imageUris.length > 0) {
                // S2-a: user bubble with album thumbnails (transient
                // uris — see LocalMessage.imageUris comment).
                Column() {
                  Column() {
                    ForEach(m.imageUris, (uri: string) => {
                      Image(uri)
                        .width(96)
                        .height(96)
                        .objectFit(ImageFit.Cover)
                        .borderRadius(8)
                        .margin({ bottom: 6 })
                    }, (uri: string) => uri)
                    Text(m.content !== '' ? m.content : $r('app.string.img_label'))
                      .fontSize(14)
                      .fontColor($r('app.color.text_inverse'))
                  }
                  .padding(10)
                  .borderRadius(10)
                  .backgroundColor(accentPrimary())
                  .constraintSize({ maxWidth: '80%' })
                  // S2-b: long-press -> action bar (copy/resend).
                  .gesture(LongPressGesture({ duration: 500 }).onAction((): void => {
                    this.onBubbleLongPress(m);
                  }))
                  // S6c: 气泡下方时间戳 / 本轮耗时（历史消息无耗时，只显时间）。
                  Text(this.bubbleMeta(m))
                    .fontSize(10)
                    .fontColor($r('app.color.text_hint'))
                    .margin({ top: 4 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.End)
                .alignSelf(ItemAlign.End)
                .margin({ top: 6, bottom: 6, left: 12, right: 12 })
              } else if (m.role !== 'user' && m.thinking !== '') {
                // BUG-001: assistant reply with a reasoning preamble —
                // render the preamble in a collapsible block (collapsed by
                // default) and the actual reply in the normal bubble.
                Column() {
                  Text(this.isThinkingExpanded(m)
                    ? $r('app.string.thinking_collapse')
                    : $r('app.string.thinking_expand'))
                    .fontSize(11)
                    .fontColor($r('app.color.text_hint'))
                    .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                    .borderRadius(8)
                    .backgroundColor($r('app.color.bg_page'))
                    .border({ width: 0.5, color: '#E0E0E0' })
                    .onClick((): void => {
                      this.toggleThinking(m);
                    })
                  if (this.isThinkingExpanded(m)) {
                    Text(m.thinking)
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                      .padding({ top: 4, bottom: 6, left: 10, right: 10 })
                      .borderRadius(8)
                      .backgroundColor($r('app.color.bg_page'))
                      .border({ width: 0.5, color: '#E0E0E0' })
                      .maxLines(30)
                  }
                  Column() {
                    this.mdView(m.content, this.mdKeyOf(m))
                  }
                  .width('100%')
                  .padding(10)
                  .borderRadius(10)
                  .backgroundColor($r('app.color.bg_subtle'))
                  .margin({ top: 6 })
                  .constraintSize({ maxWidth: '80%' })
                  .gesture(LongPressGesture({ duration: 500 }).onAction((): void => {
                    this.onBubbleLongPress(m);
                  }))
                  // S6c: 气泡下方时间戳 / 本轮耗时（历史消息无耗时，只显时间）。
                  Text(this.bubbleMeta(m))
                    .fontSize(10)
                    .fontColor($r('app.color.text_hint'))
                    .margin({ top: 4 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .alignSelf(ItemAlign.Start)
                .constraintSize({ maxWidth: '85%' })
                .margin({ top: 6, bottom: 6, left: 12, right: 12 })
              } else {
                if (m.role !== 'user') {
                  // P4⑦: assistant reply (no thinking) — lightweight Markdown
                  // 2026-11-18 fix: 气泡文字溢出——原 constraintSize({maxWidth:'80%'})
                  // 只约束最大宽度，ArkUI Column 默认 wrap-content，长文本可能撑开
                  // 超过 maxWidth 导致文字溢出左边界。加 .width('100%') 让气泡占满
                  // 父容器宽度（受父 constraintSize 限制），内部 Text 正确换行。
                  Column() {
                    Column() {
                      this.mdView(m.content, this.mdKeyOf(m))
                    }
                    .width('100%')
                    .padding(10)
                    .borderRadius(10)
                    .backgroundColor('#F5F5F5')
                    .constraintSize({ maxWidth: '80%' })
                    // S2-b: long-press -> action bar (copy + contextual items).
                    .gesture(LongPressGesture({ duration: 500 }).onAction((): void => {
                      this.onBubbleLongPress(m);
                    }))
                    // S6c: 气泡下方时间戳 / 本轮耗时（历史消息无耗时，只显时间）。
                    Text(this.bubbleMeta(m))
                      .fontSize(10)
                      .fontColor($r('app.color.text_hint'))
                      .margin({ top: 4 })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .alignSelf(ItemAlign.Start)
                  .margin({ top: 6, bottom: 6, left: 12, right: 12 })
                } else {
                  Column() {
                    Text(m.content)
                      .fontSize(14)
                      .padding(10)
                      .borderRadius(10)
                      .backgroundColor(accentPrimary())
                      .fontColor($r('app.color.text_inverse'))
                      .constraintSize({ maxWidth: '80%' })
                      // S2-b: long-press -> action bar (copy + contextual items).
                      .gesture(LongPressGesture({ duration: 500 }).onAction((): void => {
                        this.onBubbleLongPress(m);
                      }))
                    // S6c: 气泡下方时间戳 / 本轮耗时（历史消息无耗时，只显时间）。
                    Text(this.bubbleMeta(m))
                      .fontSize(10)
                      .fontColor($r('app.color.text_hint'))
                      .margin({ top: 4 })
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.End)
                  .alignSelf(ItemAlign.End)
                  .margin({ top: 6, bottom: 6, left: 12, right: 12 })
                }
              }
            }
          }, (m: LocalMessage) => String(m.id) + '_' + String(m.serverMsgId) + '_' + String(m.createdAt))

          // §R10-1 首字骨架屏：busy 且当前助手气泡还没有任何内容时，用 3 条占位条
          // 替代空白（实测缺陷：首字未到是空白区，体感像卡死）。首段文本/step
          // 到达后该条件自动变假，骨架屏立即让位；finalize 后 busy=false 同样移除。
          if (this.showThinkingSkeleton()) {
            ListItem() {
              Column() {
                Row() {
                  Column()
                    .width('40%')
                    .height(12)
                    .borderRadius(6)
                    .backgroundColor($r('app.color.divider'))
                    .opacity(this.skeletonOpacity)
                }
                .width('100%')
                .margin({ bottom: 8 })
                Row() {
                  Column()
                    .width('60%')
                    .height(12)
                    .borderRadius(6)
                    .backgroundColor($r('app.color.divider'))
                    .opacity(this.skeletonOpacity)
                }
                .width('100%')
                .margin({ bottom: 8 })
                Row() {
                  Column()
                    .width('50%')
                    .height(12)
                    .borderRadius(6)
                    .backgroundColor($r('app.color.divider'))
                    .opacity(this.skeletonOpacity)
                }
                .width('100%')
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('app.color.bg_subtle'))
              .alignSelf(ItemAlign.Start)
              .constraintSize({ maxWidth: '80%' })
              .margin({ top: 6, bottom: 6, left: 12, right: 12 })
            }
          }

          // Streaming bubble: S1 step flow (transient) above the
          // in-flight assistant text.
          if (this.v().busy && (this.v().streamText !== '' || this.v().steps.length > 0)) {
            ListItem() {
              Column() {
                if (this.v().steps.length > 0) {
                  ForEach(this.v().steps, (st: ToolStep) => {
                    Row() {
                      Text(st.state === 'error' ? '✗' : (st.state === 'ok' ? '✓' : '⋯'))
                        .fontSize(11)
                        .fontColor(st.state === 'error' ? $r('app.color.danger') : $r('app.color.text_hint'))
                        .width(14)
                      Text(this.stepLabel(st))
                        .fontSize(11)
                        .fontColor($r('app.color.text_hint'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .margin({ bottom: 2 })
                  // Key carries the state+duration so completed/running
                  // transitions re-render the row.
                  }, (st: ToolStep) => st.toolCallId + '|' + st.state + '|' + String(st.durationSec))
                }
                // P4⑦: in-flight assistant text rendered as lightweight Markdown.
                // The parser re-runs on each chunk; half-content (unclosed ** /
                // open table row) degrades to plain text safely.
                if (this.v().streamText !== '') {
                  this.mdView(this.v().streamText, '__stream__')
                } else {
                  Text(this.runDots())
                    .fontSize(14)
                }
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('app.color.bg_subtle'))
              .alignSelf(ItemAlign.Start)
              .constraintSize({ maxWidth: '80%' })
              .margin({ top: 6, bottom: 6, left: 12, right: 12 })
            }
          }
        }
        .listDirection(Axis.Vertical)
        .width('100%')
        .layoutWeight(1)

        // S1 approval card (D2): 4 choices + display countdown. The 5s
        // status poll in ChatVM is the source of truth; the card hides
        // as soon as the run leaves waiting_for_approval.
        if (this.v().pendingApproval !== null) {
          // 审批卡整块已搬到 pages/chat/ApprovalCard.ets：这里只做两件事——
          // 判断要不要创建（pendingApproval !== null），以及把收窄后的
          // 文本与回调传进去。文本仍在父页用访问器算（build() 不许写局部
          // 变量，而收窄只能发生在方法层）。
          ApprovalCard({
            command: this.approvalCommand(),
            description: this.approvalDescription(),
            statusText: this.approvalStatusText(),
            onChoice: (choice: string): void => {
              this.onApproval(choice);
            }
          })
          }

          // S2-a: pending attachment row (album picker uris, removable
          // before send; cleared on session switch / run accepted).
          if (this.v().pendingImages.length > 0) {
            Row() {
              ForEach(this.v().pendingImages, (uri: string) => {
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
                      this.onRemoveImage(uri);
                    })
                }
                .margin({ right: 8 })
              }, (uri: string) => uri)
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 4 })
          }

          // S2-b: bubble action bar (contextual; above the input row).
          if (this.menuFor !== null) {
            Row() {
              if (this.menuHasText()) {
                Button($r('app.string.act_copy'))
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .margin({ right: 6 })
                  .backgroundColor($r('app.color.divider'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick((): void => { this.onMenuCopy(); })
              }
              if (this.menuIsUser()) {
                Button($r('app.string.act_resend'))
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .margin({ right: 6 })
                  .backgroundColor(accentTint())
                  .fontColor(accentPrimary())
                  .onClick((): void => { this.onMenuResend(); })
              }
              if (this.v().busy) {
                Button($r('app.string.act_stop_gen'))
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .margin({ right: 6 })
                  .backgroundColor($r('app.color.danger'))
                  .fontColor($r('app.color.text_inverse'))
                  .onClick((): void => { this.onMenuStop(); })
              }
              if (this.v().pendingApproval !== null) {
                Button($r('app.string.act_handle_appr'))
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .margin({ right: 6 })
                  .backgroundColor($r('app.color.warning_amber'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick((): void => { this.onMenuApprove(); })
              }
              if (this.menuHasText()) {
                Button($r('app.string.act_quote'))
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .margin({ right: 6 })
                  .backgroundColor($r('app.color.divider'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick((): void => { this.onMenuQuote(); })
              }
              Button($r('app.string.act_delete'))
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .margin({ right: 6 })
                .backgroundColor($r('app.color.divider'))
                .fontColor($r('app.color.danger'))
                .onClick((): void => { this.onMenuDelete(); })
              Button('✕')
                .fontSize(13)
                .height(36)
                .width(36)
                .backgroundColor($r('app.color.text_hint'))
                .fontColor($r('app.color.text_inverse'))
                .onClick((): void => { this.closeBubbleMenu(); })
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 6 })
            .backgroundColor($r('app.color.bg_page'))
            .borderRadius(10)
          }

          // S2-b: replying-to bar (quote context) — above the input.
          if (this.hasQuote()) {
            Row() {
              Text($r('app.string.replying'))
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
              Text(this.quoteText())
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
                .onClick((): void => { this.onClearQuote(); })
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 4 })
            .backgroundColor($r('app.color.bg_subtle'))
            .borderRadius(8)
          }
          Row() {
            // U4: unified input bar — camera + text + mic live inside one
            // rounded container (the icons sit "in" the input, not beside
            // it). The action button (发送 / 停止+插话) sits to the right.
            // While a run is active the bar is a plain input (steer mode);
            // while listening it shows the live text + adopt/discard.
            // BUG-005: guard against a transiently-null vm during a
            // @Prop-triggered re-render (v() force-casts; an unguarded
            // access silently drops the whole input Row).
            if (this.vm !== null && !this.v().busy) {
              if (this.v().voiceState === 'idle') {
                Row() {
                  Text('📷')
                    .fontSize(18)
                    .margin({ left: 10, right: 6 })
                    .onClick(() => {
                      this.onPickImage();
                    })
                  TextInput({ placeholder: $r('app.string.input_ph'), text: this.inputText })
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor($r('app.color.bg_card'))
                    .borderRadius(18)
                    .onChange((v: string) => {
                      this.inputText = v;
                    })
                  Text('🎤')
                    .fontSize(18)
                    .margin({ left: 6, right: 10 })
                    .onClick(() => {
                      this.onMicTap();
                    })
                }
                .layoutWeight(1)
                .height(48)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(24)
                .alignItems(VerticalAlign.Center)
              } else {
                Row() {
                  Text(this.v().voicePartial !== '' ? this.v().voicePartial : $r('app.string.voice_recognizing'))
                    .fontSize(12)
                    .fontColor($r('app.color.danger_deep'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                    .padding({ left: 10 })
                  Button('⏹')
                    .height(36)
                    .width(36)
                    .margin({ right: 6 })
                    .backgroundColor($r('app.color.success'))
                    .fontColor($r('app.color.text_inverse'))
                    .onClick((): void => { this.onVoiceFinish(); })
                  Button('✕')
                    .height(36)
                    .width(36)
                    .margin({ right: 10 })
                    .backgroundColor($r('app.color.text_hint'))
                    .fontColor($r('app.color.text_inverse'))
                    .onClick((): void => { this.onVoiceCancel(); })
                }
                .layoutWeight(1)
                .height(48)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(24)
                .alignItems(VerticalAlign.Center)
              }
            } else {
              // Steer mode: plain input bar (camera/mic hidden while a run
              // is active).
              TextInput({ placeholder: $r('app.string.input_ph_busy'), text: this.inputText })
                .height(48)
                .layoutWeight(1)
                .backgroundColor($r('app.color.bg_subtle'))
                .borderRadius(24)
                .padding({ left: 12, right: 12 })
                .onChange((v: string) => {
                  this.inputText = v;
                })
            }
            if (this.vm !== null && this.v().busy) {
              Button($r('app.string.btn_stop'))
                .height(40)
                .margin({ left: 8 })
                .backgroundColor($r('app.color.danger'))
                .fontColor($r('app.color.text_inverse'))
                .onClick(() => {
                  this.onStopRequested();
                })
              Button($r('app.string.btn_steer'))
                .height(40)
                .margin({ left: 6 })
                .enabled(this.inputText.trim() !== '')
                .backgroundColor($r('app.color.warning_amber'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => {
                  this.onSteer();
                })
            } else if (this.vm !== null && this.v().voiceState === 'idle') {
              // S2-c: send is hidden while a voice round is live (the
              // adopt/discard buttons own the bar until it ends).
              Button($r('app.string.btn_send'))
                .height(40)
                .margin({ left: 8 })
                .enabled(this.inputText.trim() !== '' || (this.vm !== null && this.v().pendingImages.length > 0))
                .onClick(() => {
                  this.onSend();
                })
            }
          }
          .width('100%')
          .padding(12)
          .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')

    // S1: 会话面板（本地 + 服务端合并）—— 已抽成 pages/chat/SessionPanel.ets
    // 父页只提供数据（visibleRows / emptySessionCount）与回调，面板自身不持有 VM。
    if (this.vm !== null && this.showServerSessions) {
      SessionPanel({
        rows: this.visibleRows(),
        loading: this.v().serverSessionsLoading,
        errText: this.v().error,
        emptyCount: this.emptySessionCount(),
        hideEmpty: this.hideEmpty,
        sessionQuery: this.sessionQuery,
        onToggleHide: (): void => {
          this.hideEmpty = !this.hideEmpty;
        },
        onQueryChange: (val: string): void => {
          this.sessionQuery = val;
        },
        onRefresh: (): void => {
          if (this.vm !== null) {
            this.vm.listServerSessions();
          }
        },
        onClose: (): void => {
          this.showServerSessions = false;
        },
        onPick: (m: MergedSession): void => {
          if (m.isLocal && m.pk !== '') {
            this.onOpenSession(m.pk);
            this.showServerSessions = false;
          } else {
            this.onTakeover(m.sessionId, m.title);
          }
        },
        onRowLongPress: (m: MergedSession): void => {
          this.onSessionLongPress(m);
        },
        fmtCount: (n: number): string => this.fmtCount(n),
        fmtTime: (tsSec: number): string => this.sessionTime(tsSec)
      })
    }
    // P2: 未登录闸门覆盖层已搬到 pages/chat/LoginGate.ets。
    // 判断仍在这里：vm 就绪且 authMode === 'loggedOut' 时才创建；登录成功后
    // profileVer 抬升 → 重连 → /me 通过 → authMode 翻转 → 本组件不再被创建。
    if (this.vm !== null && this.v().authMode === 'loggedOut') {
      LoginGate({
        errText: this.v().error,
        onOpenLogin: (): void => {
          this.gotoLogin();
        }
      })
    }
    }
    .width('100%')
    .height('100%')
  }
}
