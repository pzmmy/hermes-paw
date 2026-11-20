// =====================================================================
// viewmodel/ChatVM.ets — chat screen state (M1: session list, message
// history, send + SSE streaming; S1: step flow, approval card,
// steer, stop, background/disconnect retrieval)
// 中文：聊天页状态机 —— 会话列表 / 历史消息 / 发送与 SSE 流 / S1 步骤流、审批卡、插话、停止、后台恢复
//
// Streaming contract (evidence-verified 2026-10-27/29):
//   message.delta   -> append data['delta'] to the in-flight text
//   tool.started    -> step row (tool / preview / tool_call_id)
//   tool.completed  -> step row duration (s) + ok/error
//   approval.request -> approval card: 4 choices + 60s display
//     countdown (D2: no API exposes the timeout; the 5s poll of
//     GET /v1/runs/{id} is the only source of truth)
//   approval.settled -> card resolved (polling confirms the outcome)
//   run.completed / run.failed / run.cancelled / run.interrupted
//     -> terminal: finalize (server output preferred over the partial
//     local text), persist, busy=false
//
// Durable-run retrieval (S1 + §R0, plan §4.3; S3-b revised):
//   - the baseline getRun poll is the ONLY retrieval channel: it starts
//     right after the run is created and runs through the whole run
//     until a terminal snapshot finalizes it; SSE is an enhancement
//     (incremental rendering, lower latency) and its failure never
//     changes the verdict on the run
//   - background: stream destroyed, run state kept; on foreground the
//     still-armed baseline poll keeps fetching
//   - terminal run while blind: one-shot replay backfill; if the
//     server no longer replays, finalize from the run snapshot
// =====================================================================
import { Msg } from '../utils/Msg';
import { http } from '@kit.NetworkKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { ApiClient, ApiError } from '../net/ApiClient';
import { describeError, classifyStreamError, describeStreamError, StreamErrorKind } from '../net/ErrorText';
import { RunsApi } from '../net/RunsApi';
import { SessionInfo, SessionsApi } from '../net/SessionsApi';
import { SseEvent, SseParser, isTerminalSseEvent } from '../net/SseParser';
import { AuthApi, authErrorCode } from '../net/AuthApi';
import { AuthIdentity, loadAuthIdentity, clearAuthIdentity } from '../store/AuthSession';
import { DbHelper } from '../store/DbHelper';
import { TokenVault } from '../store/TokenVault';
import { LocalMessage, MessageRole, ServerMessage, splitThinking } from '../model/ChatMessage';
import { LocalSession, buildLocalPk } from '../model/LocalSession';
import { MergedSession, deriveLocalTitle, mergeSessions, fallbackTitle } from './SessionMerge';
import { ServerProfile } from '../model/Profile';
import { ApprovalControl, RunSnapshot, isTerminalStatus, parseApprovalControl } from '../model/Run';
import { ToolStep } from '../model/ToolStep';
import { MM_MAX_IMAGES, buildUserMessage } from '../model/Multimodal';
import { SessionStore, TitleSync } from './session/SessionStore';
import { PreparedImage, pickImages, prepareImage } from '../media/PhotoPick';
import { SlashCommand, slashName, slashArg, findCommand, isKnownUnmapped } from '../net/SlashCommands';
import { GiveUpReason, decideGiveUp, isKnownActiveStatus } from './stream/RunPolicy';
import { POLL_START_MS, POLL_SSE_ACTIVE_MS, nextPollInterval } from './stream/PollPolicy';

const TAG: string = 'ChatVM';

/** §4.5 retention (per profile): keep the newest N sessions or 90 days,
 * first hit wins. Local prune is lossless — the server session store is
 * the source of truth and pruned history is re-fetchable. */
const RETENTION_MAX_SESSIONS: number = 200;
const RETENTION_MAX_AGE_MS: number = 90 * 24 * 60 * 60 * 1000;

/** S1 approval card (D2): local display countdown is a hardcoded 60s;
 *  the 5s status poll is the sole source of truth. */
const APPROVAL_TIMEOUT_SEC: number = 60;
const APPROVAL_POLL_MS: number = 5000;
const COUNTDOWN_TICK_MS: number = 1000;
/** §R0 双通道并行（本仓 2026-11-18 实测基线）：基线 getRun 轮询的拍距与
 *  自适应参数（S7a 起改由 stream/PollPolicy.ets 提供）。 */
/** P1：等待期计时器拍距（秒级推进「已用时 N 秒」）。 */
const ELAPSED_TICK_MS: number = 1000;
/** Vault-probe retry (home-E2E 2026-11-01, ready jitter): the HUKS
 *  system service can still be warming up right after a cold app
 *  start — a single probe failure then leaves the whole data plane
 *  gated off (ready=false) until the user re-activates in settings.
 *  Retry with linear delay before giving up. */
const VAULT_RETRY_DELAY_MS: number = 1500;
const VAULT_MAX_ATTEMPTS: number = 3;

function boolFrom(v: Object | null | undefined): boolean {
  return v === true;
}

/** P3-03 修：ASR 录音超长/超时的错误码集合。HarmonyOS on-device ASR 对
 *  超长录音返回 1002200003（及同族的时长/超时类错误）。命中则提示"录音过长"，
 *  而非笼统的"识别失败"（易被误读成网络/Token 问题）。 */
function isVoiceTooLongCode(code: number): boolean {
  return code === 1002200003 || code === 1002200001 || code === 1002200002;
}

/**
 * Chat screen view model: local history first, server truth on reopen.
 *
 * ── 运行态状态机（2026-11-18 文档；S3-b 后修订）─────────────────────
 *  取数模型：**基线 getRun 轮询是唯一取数通道**（sendMessage 建 run 成功即启动，
 *  贯穿整个 run 直到终态收口）；SSE 只做增强（增量渲染 / 低延迟），它挂掉不影响
 *  结果取回。原退避轮询式 recovery 子系统已删除（被基线轮询的首行守卫永久挡死，
 *  属不可达代码）。
 *
 *  核心状态字段：
 *  - busy: boolean            — 是否有活跃 run（sendMessage 置 true，finalizeRun 置 false）
 *  - pollingForResult: boolean— 残留兼容位（S3-b 后恒 false，UI 仍绑定该字段）
 *  - streamGen: number        — 流代数；destroyStream/openRunStream 时自增，让旧流回调被丢弃
 *  - baselinePollTimer: number— 基线轮询 ticker 句柄（-1 = 未运行）
 *
 *  状态迁移：
 *  [idle] ──sendMessage──▶ [running: 基线轮询 + SSE 增强 并行]
 *                                  │
 *                     SSE 吐 delta │ getRun 终态 / 放弃判据命中
 *                     (增量渲染)   │ (finalizeRun)
 *                                  ▼
 *                         [idle: busy=false, 轮询停]
 *
 *  关键不变量：
 *  - 基线轮询是唯一取数通道：SSE 错误/重开失败都只记日志，不改判 run 的生死
 *  - 同一 run 在飞 getRun ≤1（baselinePollInFlight 守卫，本轮 tick 直接跳过）
 *  - 旧流回调必须被 streamGen 守卫丢弃（destroyStream 取消不掉 SDK 内部定时器）
 *  - finalizeRun 是唯一的「终态收口」：busy=false + pollingForResult=false
 *    都在此统一复位，不要在其他地方散落复位
 * ────────────────────────────────────────────────────────────────────
 */
export class ChatVM {
  // ---- reactive state (the page binds via @State vm: ChatVM | null) ----
  ready: boolean = false;
  /** S3-r1 (home-E2E 2026-11-01): a lazy reconnect is in flight —
   *  concurrent guarded taps share the single connect() attempt. */
  private reconnecting: boolean = false;
  sessions: LocalSession[] = [];
  messages: LocalMessage[] = [];
  streamText: string = '';
  /** S1 step flow: tool.started/completed pairs (transient, per run). */
  steps: ToolStep[] = [];
  /** S1: pending approval card (null = no card). */
  pendingApproval: ApprovalControl | null = null;
  /** S1: display-only countdown seconds (D2; polling is the truth). */
  approvalCountdownSec: number = 0;
  /** S1: server session list for the takeover panel (transient). */
  serverSessions: SessionInfo[] = [];
  /** S1: true while the takeover panel is refreshing. */
  serverSessionsLoading: boolean = false;
  busy: boolean = false;
  /** 2026-11-18 空窗期提示（S3-b 后为残留兼容位）：唯一置 true 的位置曾是已删除的
   *  退避 recovery 通道，故本例恒 false——UI 状态条仍绑定该字段，收口时复位。
   *  取数本身由基线轮询负责（内网直连实验：SSE 全吞帧期间只有计时器在走，
   *  体验像卡死，故 UI 保留这个「正在获取结果」的绑定位）。 */
  pollingForResult: boolean = false;
  /** 展示用：最近一次收口时刻（epoch ms；-1 = 从未收口）。UI 按
   *  Date.now() - justFinishedMs < 3000 判断「刚收到」，**不靠定时器清理**。 */
  justFinishedMs: number = -1;
  /** 展示用：最近一次收口的正文字数（配合 justFinishedMs 出「已收到 N 字」）。 */
  justFinishedChars: number = 0;
  /** §R3 ③：「重开取回」入口状态位——abandoned-remote 收口时 true，
   *  表示客户端已放弃等待但 run 仍在服务端，UI 可给重开入口。下次
   *  新 run / 正常收口时复位。 */
  canReopenRemote: boolean = false;
  hasSession: boolean = false;
  activePk: string = '';
  /** S2-a: pending album picker uris shown as the attachment chip row
   *  above the input bar; cleared on session switch and after the run
   *  is accepted (202). */
  pendingImages: string[] = [];
  /** S2-c: voice input state: 'idle' | 'listening' (D5: while listening
   *  the input row swaps the attach/mic buttons for the live text +
   *  adopt/discard buttons). */
  voiceState: string = 'idle';
  /** S2-c: live recognition text (settled clauses + current partial),
   *  shown in the input row while listening. */
  voicePartial: string = '';
  error: string = '';
  notice: string = '';
  /** A1: epoch-ms when the current run started (0 = no active run);
   *  the page ticks a 1s timer to render the elapsed indicator. */
  runStartedAt: number = 0;
  /** E3: green "已连接" status set by connect() on success (dismissible
   *  in the page); distinct from the transient blue `notice`. */
  success: string = '';
  /** BUG-005: auto-dismiss timer for the success bar. A persistent green
   *  bar occupies the top of the chat Column; while it stays, the ArkUI
   *  if/else-if chain plus this.v() reference tracking can skip re-diffing
   *  the sibling chat body (List) on re-render, so the user sees only the
   *  bar and an empty area. Auto-clearing after a few seconds (and on the
   *  × tap) keeps the bar transient, so it never wedges the chat UI. */
  private successTimerId: number = -1;

  /** BUG-005 fix2: UI-change callback. @State on a plain (non-@Observed)
   *  class only tracks the reference, not the inner fields — so mutating
   *  this.messages / this.busy / this.streamText never re-renders the page.
   *  The page injects a callback that bumps its own @State version counter;
   *  every user-visible state mutation below calls notifyUi() so the ForEach
   *  / conditional re-runs within one frame. Assigned to a no-op in the
   *  constructor (ArkTS rejects an arrow-function initializer inline on a
   *  function-typed field); the page overwrites it after vm creation. */
  onUiChange: () => void;

  /** BUG-005 fix2: fire the page re-render hook. Always invoked from the
   *  VM's own sync context, so the page bump is synchronous and the next
   *  frame sees the new state. */
  private notifyUi(): void {
    this.onUiChange();
  }

  // ---- private members ----
  private ctx: common.Context;
  private db: DbHelper;
  private store: SessionStore;
  private profile: ServerProfile;
  private client: ApiClient;
  private runs: RunsApi;
  private sessionsApi: SessionsApi;
  private auth: AuthApi;
  /** P2: 用户会话闸门状态（设计文档 §9）：'legacy' = 网关无
   *  /api/auth（或探测不可达：离线）——不拦数据面，P2 前行为；
   *  'loggedOut' = D3 门生效且无有效会话——数据面关闭，页面展示登录
   *  入口；'loggedIn' = 有效会话，ApiClient 附 X-User-Session。
   *  初始 'legacy'，connect() + kickoffAuthProbe() 决议。 */
  authMode: string = 'legacy';
  private parser: SseParser | null = null;
  private streamReq: http.HttpRequest | null = null;
  private activeSessionId: string = '';
  private activeRunId: string = '';
  private currentTitle: string = '';
  private terminalReceived: boolean = false;
  /** P4⑤: the last user message sent in this session (for "retry last"
   *  after a failed send/stream). Null until the first send. */
  private lastUserMsg: LocalMessage | null = null;
  /** S2-b: quote context (引用) — the message the user is replying to.
   *  One-shot: consumed (cleared) by the next sendMessage. Null = not
   *  replying to anything. Public so the page renders the "回复中" bar. */
  quoteContext: LocalMessage | null = null;
  /** Set when stopStream() runs before the run exists; handled by
   *  sendMessage right after createRun (batch2 P1-03 edge). */
  private stopRequested: boolean = false;
  /** S1: last seq applied for the current run (resubscribe dedupe gate). */
  private lastSeq: number = -1;
  /** S1: stream generation counter — callbacks from destroyed (stale)
   *  requests are dropped on gen mismatch. */
  private streamGen: number = 0;
  /** S1: true while the app is backgrounded (stream destroyed, timers
   *  frozen); cleared by resumeFromBackground. */
  private suspended: boolean = false;
  /** S1: one-shot replay backfill of a run that went terminal while the
   *  stream was down; if the replay ends without a terminal frame,
   *  onStreamEnd finalizes from terminalSnap. */
  private backfill: boolean = false;
  private terminalSnap: RunSnapshot | null = null;
  /** S1 approval state (D2). */
  private approvalDeadline: number = 0;
  private approvalActed: boolean = false;
  private approvalPollId: number = -1;
  private countdownId: number = -1;
  /** S3-b 残留守卫位：原 recovery 子系统已删除，取数由基线轮询独占，此值恒 0。
   *  保留仅为 onStreamError 里「旧流误报不打断取数」的守卫语义（不新增路径）。 */
  private streamPolls: number = 0;
  /** S2-c: on-device ASR engine (CoreSpeechKit). D2: a fresh engine per
   *  listening round (create + shutdown), never shared across rounds. */
  private asrEngine: speechRecognizer.SpeechRecognitionEngine | null = null;
  /** S2-c: sessionId of the current round (finish/cancel target). */
  private voiceSessionId: string = '';
  /** S2-c: settled (isFinal) clauses accumulated this round. */
  private voiceAccum: string = '';
  /** S2-c: the user tapped discard (✕) — the round's text is dropped. */
  private voiceDiscarded: boolean = false;
  /** S2-c: the round already ended (onComplete/onError) — one-shot guard
   *  for the finalize + shutdown pair. */
  private voiceEnded: boolean = false;
  /** S2-c: page callback receiving the final text (D3: fills the input
   *  field; the user confirms the send). */
  private voiceOnFinal: (text: string) => void = (text: string): void => {
  };

  // ---- §R0 基线轮询（getRun 为基线，SSE 只做增强）----
  /** 基线轮询 ticker 句柄（setInterval；-1 = 未运行）。单一 ticker 驱动，
   *  禁止嵌套定时器竞速（ArkTS async 下实测不可靠，S3-b 前的 recovery 通道即因此废弃）。 */
  private baselinePollTimer: number = -1;
  /** 并发不变量（§R0-3）：同一 run 在飞 getRun ≤1 —— 在飞时本轮 tick 直接跳过。 */
  private baselinePollInFlight: boolean = false;
  /** 当前拍距（自适应：无变化翻倍，上限 10s；SSE 活跃时提到 10s）。 */
  private baselinePollIntervalMs: number = POLL_START_MS;
  /** 基线轮询跟踪的 run id（与 activeRunId 分开，收口时各自复位）。 */
  private baselineRunId: string = '';
  /** 上一次快照 output（判定「连续无变化」用）。 */
  private baselineLastOutput: string = '';
  /** 连续无变化轮数（命中 3 次翻倍后清零）。 */
  private baselineIdleRounds: number = 0;
  /** 当前气泡文本是否由快照写入（决定 SSE delta 到达时的去重/合并策略）。 */
  private baselineTextFromSnapshot: boolean = false;
  /** §R3 ①：连续 getRun 抛异常/超时次数（成功拿到已识别状态即归零）。 */
  private failStreak: number = 0;
  /** §R3 ②：连续未知状态次数（成功拿到已识别状态即归零）。 */
  private unknownStreak: number = 0;
  /** §R3 ②：最后一个未知 status 原名（诊断码，原样带进 UI）。 */
  private lastUnknownStatus: string = '';
  /** §R3 ③：本轮 baseline 轮询起算时刻（绝对上限 30min 的基准，不用墙钟放弃）。 */
  private baselineStartAt: number = 0;
  /** §R3：收口时带走的诊断码（protocol-error 用；UI 文案拼接用）。 */
  private giveUpDetail: string = '';
  /** P1：等待期已用秒数（UI 状态条读这个字段，替代按 runStartedAt 现算）。 */
  private elapsedTimer: number = -1;
  /** S6a 埋点：首个增量（SSE chunk / 轮询非空 output）到达时刻，0 = 尚无。 */
  private firstDeltaAt: number = 0;
  /** S6a 埋点：上一拍快照 output 长度（判定本轮是否已出现增量）。 */
  private lastOutLen: number = 0;
  /** S6a 埋点：本轮 getRun 拍号（每 run 复位，用于对齐日志与拍距）。 */
  private pollSeq: number = 0;
  elapsedSec: number = 0;

  constructor(ctx: common.Context, db: DbHelper, profile: ServerProfile) {
    this.ctx = ctx;
    this.db = db;
    this.profile = profile;
    this.client = new ApiClient();
    this.runs = new RunsApi(this.client);
    this.sessionsApi = new SessionsApi(this.client);
    this.store = new SessionStore(this.db, this.sessionsApi, this.profile);
    this.auth = new AuthApi(this.client);
    // BUG-005 fix2: default the UI-change hook to a no-op (ArkTS rejects an
    // inline arrow-function initializer on this field); the page overwrites
    // it right after vm creation. notifyUi() is safe before that override.
    this.onUiChange = (): void => {};
  }

  /**
   * Load the token and configure the client. This method performs no
   * network call; the chat page can render an offline/local view first.
   */
  async connect(): Promise<void> {
    if (!this.profile.isConfigured()) {
      this.error = Msg.t('m_vm_no_addr');
      this.ready = false;
      return;
    }
    // HUKS availability gate (batch2-r6 D-01, refined in r7): probe
    // at the data-plane entry; only fatal when this profile actually
    // stores a token — an unauthenticated gateway needs no vault
    // access at all.
    // Home-E2E 2026-11-01 (ready jitter): the HUKS system service can
    // still be warming up right after a cold app start — a single
    // probe/load failure then leaves the data plane gated off until
    // the user re-activates in settings. Retry before giving up.
    let token: string = '';
    let tokenLoaded: boolean = false;
    let attempts: number = 0;
    while (!tokenLoaded && attempts < VAULT_MAX_ATTEMPTS) {
      attempts = attempts + 1;
      let hasStored: boolean = false;
      try {
        hasStored = await TokenVault.hasToken(this.ctx, this.profile.vaultRef());
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        LogSafe.w(TAG, 'hasToken failed: code=%{public}d message=%{public}s',
          e.code, String(e.message));
      }
      let vaultOk: boolean = await TokenVault.isAvailable();
      if (!vaultOk && hasStored) {
        if (attempts < VAULT_MAX_ATTEMPTS) {
          LogSafe.w(TAG, 'vault unavailable (attempt %{public}d/%{public}d), retrying',
            attempts, VAULT_MAX_ATTEMPTS);
          await this.delay(VAULT_RETRY_DELAY_MS * attempts);
          continue;
        }
        LogSafe.w(TAG, 'token vault unavailable (syscap missing)');
        this.error = Msg.t('m_vm_no_secure_store');
        this.ready = false;
        return;
      }
      try {
        token = await TokenVault.loadToken(this.ctx, this.profile.vaultRef());
        tokenLoaded = true;
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        LogSafe.w(TAG, 'load token failed: code=%{public}d message=%{public}s',
          e.code, String(e.message));
        if (attempts < VAULT_MAX_ATTEMPTS) {
          LogSafe.w(TAG, 'token load failed (attempt %{public}d/%{public}d), retrying',
            attempts, VAULT_MAX_ATTEMPTS);
          await this.delay(VAULT_RETRY_DELAY_MS * attempts);
          continue;
        }
        this.error = Msg.t('m_vm_read_token_fail');
        this.ready = false;
        return;
      }
    }
    // Token optional (batch2-r7): gateways may run unauthenticated;
    // an empty token → ApiClient sends no Bearer header (P2-15).
    if (token === '') {
      LogSafe.i(TAG, 'no token for this profile; connecting unauthenticated');
    }
    this.client.configure(this.profile.baseUrl, token, this.profile.role,
      this.profile.pf);
    // P2: 从 TokenVault 恢复用户会话（本地 HUKS 读——connect() 仍无
    // 网络调用），并在任何数据面请求之前挂好 header。网络校验
    // （GET /api/auth/me）异步进行，见 kickoffAuthProbe。
    let identity: AuthIdentity | null = null;
    try {
      identity = await loadAuthIdentity(this.ctx, this.profile);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      LogSafe.w(TAG, 'auth identity load failed: code=%{public}d', e.code);
      identity = null;
    }
    if (identity !== null) {
      this.client.setUserSession(identity.token);
    } else {
      this.client.setUserSession('');
    }
    this.ready = true;
    this.error = '';
    this.success = Msg.t('m_vm_connected') + this.profile.name;
    // BUG-005: auto-dismiss the success bar so it stays transient (a
    // persistent bar wedges the chat body — see successTimerId comment).
    if (this.successTimerId !== -1) {
      clearTimeout(this.successTimerId);
    }
    this.successTimerId = setTimeout((): void => {
      this.successTimerId = -1;
      this.clearSuccess();
    }, 4000);
    this.notifyUi();
    this.kickoffAuthProbe();
  }

  /**
   * Lazy re-validation (home-E2E 2026-11-01: ready jitter). The client
   * is request-scoped — http.createHttp() per request, no persistent
   * socket — so "connected" means "profile + token vault validated",
   * not a held TCP connection (a heartbeat would have nothing to
   * keep alive). A transient vault failure at cold start can leave
   * ready=false with no user-visible recovery path other than
   * re-activating in settings. Guarded actions call this instead of
   * failing outright: the first blocked tap re-runs connect (which
   * carries its own vault retry) and subsequent taps within the
   * attempt window see a hint, not a dead end.
   */
  private async ensureReady(): Promise<boolean> {
    if (this.ready) {
      return true;
    }
    if (this.reconnecting) {
      this.error = Msg.t('m_vm_connecting');
      return false;
    }
    this.reconnecting = true;
    try {
      await this.connect();
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'reconnect failed: %{public}s', e.message);
      if (this.error === '') {
        this.error = Msg.t('m_vm_connect_fail');
      }
    }
    this.reconnecting = false;
    return this.ready;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  /** P2: 对网关校验（或发现）用户会话——fire-and-forget，绝不延迟
   *  冷启动（设计文档 §9）。决议表：
   *    200            → 'loggedIn'（有效；服务端滑动 TTL）
   *    401            → 'loggedOut'（需要会话且无有效会话；如有陈旧
   *                     本地副本则清除）
   *    404            → 'legacy'（P1 前网关无 /api/auth——清掉永远
   *                     用不上的陈旧会话）
   *    网络 / 5xx     → 'legacy'（网关不可达——离线使用不得被一个
   *                     无法判定的探测拦死） */
  private kickoffAuthProbe(): void {
    let vm: ChatVM = this;
    this.auth.me().then((): void => {
      vm.authMode = 'loggedIn';
      LogSafe.i(TAG, 'auth probe: session valid (loggedIn)');
      vm.notifyUi();
    }).catch((err: Error): void => {
      let ae: ApiError | null = null;
      if (err instanceof ApiError) {
        ae = err;
      }
      let code: number = ae === null ? 0 : ae.code;
      if (code === 404) {
        vm.authMode = 'legacy';
        LogSafe.i(TAG, 'auth probe: 404 → legacy gateway (no auth)');
        vm.dropAuthIdentity();
      } else if (code === 401) {
        vm.authMode = 'loggedOut';
        LogSafe.w(TAG, 'auth probe: 401 → signed out (D3 gate)');
        vm.dropAuthIdentity();
      } else {
        vm.authMode = 'legacy';
        LogSafe.w(TAG, 'auth probe failed (code=%{public}d) → legacy', code);
      }
      vm.notifyUi();
    });
  }

  /** P2: 摘除会话 header 并清本地 TokenVault 副本（静默）。 */
  private dropAuthIdentity(): void {
    this.client.setUserSession('');
    clearAuthIdentity(this.ctx, this.profile).catch((err: Error): void => {
      LogSafe.w(TAG, 'auth identity clear failed: %{public}s', err.message);
    });
  }

  /** P2: 数据面错误是否为 D3 会话门（401 + error.code =
   *  'user_session_required'）——会话已被吊销/过期，清本地副本并
   *  回落未登录闸门。 */
  private sessionRequired(err: Error): boolean {
    if (err instanceof ApiError) {
      let ae: ApiError = err;
      return ae.code === 401 && authErrorCode(ae) === 'user_session_required';
    }
    return false;
  }

  /** Refresh the local session list (updated_at desc). */
  async listLocalSessions(): Promise<void> {
    try {
      this.sessions = await this.store.listLocal();
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'list local sessions failed: %{public}s', e.message);
      this.error = Msg.t('m_vm_read_local_fail');
    }
  }

  /** Create a server session, persist it locally, and open it. */
  async newSession(): Promise<void> {
    if (!(await this.ensureReady())) {
      return;
    }
    if (this.busy) {
      return;
    }
    try {
      // S9a：不再传占位名。空标题 = 交给网关按首条消息自动命名
      // （derive_title → llm 升级 3-7 词）；占位名会以非 derived 权威落库，
      // 把自动命名永久封死（impl-status §2.7）。
      let title: string = '';
      let sid: string = await this.sessionsApi.createSession(title);
      let now: number = Date.now();
      let s: LocalSession = new LocalSession();
      s.serverId = this.profile.serverId;
      s.pf = this.profile.pf;
      s.role = this.profile.role;
      s.sessionId = sid;
      s.pk = buildLocalPk(s.serverId, s.pf, s.role, s.sessionId);
      s.title = title;
      s.createdAt = now;
      s.updatedAt = now;
      await this.db.upsertSession(s);
      this.activePk = s.pk;
      this.activeSessionId = sid;
      this.currentTitle = title;
      this.hasSession = true;
      this.clearPendingImages(); // S2-a: attachments belong to the old session
      this.messages = [];
      this.streamText = '';
      this.steps = [];
      this.lastSeq = -1;
      this.terminalReceived = false;
      this.backfill = false;
      this.terminalSnap = null;
      this.error = '';
      this.notice = '';
      this.clearApprovalState();
      LogSafe.d(TAG, 'session opened');
      await this.listLocalSessions();
    } catch (err) {
      let e: Error = err as Error;
      this.error = Msg.t('m_vm_new_session_fail') + describeError(e);
    }
  }

  /**
   * Open a saved session: show local rows immediately, then refetch
   * the server history (S-01) and replace it with server truth.
   */
  async openSession(pk: string): Promise<void> {
    if (!(await this.ensureReady())) {
      return;
    }
    if (this.busy) {
      return;
    }
    let s: LocalSession | null = null;
    try {
      s = await this.db.getSession(pk);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'get session failed: %{public}s', e.message);
      this.error = Msg.t('m_vm_read_session_fail') + e.message;
      return;
    }
    if (s === null) {
      this.error = Msg.t('m_vm_session_missing');
      return;
    }
    this.activePk = pk;
    // Replace the array reference so the session-strip ForEach re-diffs
    // and the active highlight moves (the key carries the active flag,
    // batch2-r2 P0-B class).
    this.sessions = this.sessions.slice();
    this.activeSessionId = s.sessionId;
    this.currentTitle = s.title;
    this.hasSession = true;
    this.clearPendingImages(); // S2-a: attachments belong to the previous session
    this.streamText = '';
    this.steps = [];
    this.lastSeq = -1;
    this.terminalReceived = false;
    this.backfill = false;
    this.terminalSnap = null;
    this.error = '';
    this.notice = '';
    this.clearApprovalState();

    // Local-first display.
    try {
      this.messages = await this.db.loadMessages(pk);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'load local messages failed: %{public}s', e.message);
      this.messages = [];
    }

    // Server refetch: replace local cache with server truth.
    try {
      let msgs: ServerMessage[] = await this.sessionsApi.fetchMessages(this.activeSessionId);
      let now: number = Date.now();
      let local: LocalMessage[] = [];
      for (let i = 0; i < msgs.length; i++) {
        let sm: ServerMessage = msgs[i];
        let lm: LocalMessage = new LocalMessage();
        lm.key = pk;
        lm.sessionId = sm.session_id;
        lm.role = sm.role;
        // BUG-001 boundary: server-stored assistant history also merges the
        // reasoning preamble into `content`. Split it the same way as a live
        // run (finalizeRun) so the preamble renders collapsed on session
        // reopen instead of as a wall of raw text. User messages are left
        // verbatim (no thinking).
        if (sm.role === MessageRole.ASSISTANT) {
          let parts: string[] = splitThinking(sm.content);
          lm.thinking = parts[0];
          lm.content = parts[1];
        } else {
          lm.content = sm.content;
        }
        lm.serverMsgId = sm.id;
        lm.timestamp = sm.timestamp;
        lm.truncated = false;
        lm.createdAt = now;
        local.push(lm);
      }
      // Wipe local-only rows (server_msg_id=0) before saving server truth:
      // saveMessages upsert reconciliation does not cover them, so without
      // the wipe every server-assigned message would appear twice. The wipe
      // runs only after a successful fetch; on fetch failure the catch below
      // keeps the local cache intact.
      await this.db.deleteMessages(pk);
      await this.db.saveMessages(local);
      this.messages = local;
      this.notifyUi();
      s.updatedAt = now;
      await this.db.upsertSession(s);
      await this.listLocalSessions();
      LogSafe.d(TAG, 'session history refreshed: count=%{public}d', local.length);
    } catch (err) {
      let e: Error = err as Error;
      if (this.sessionRequired(e)) {
        this.authMode = 'loggedOut';
        this.dropAuthIdentity();
        this.error = Msg.t('m_vm_login_expired');
        this.notifyUi();
      } else {
        this.notice = Msg.t('m_vm_history_fail') + describeError(e);
      }
    }
  }

  /**
   * S2-a: open the album picker and append the chosen uris to the
   * pending attachment row (permission-free picker).
   */
  async pickImages(): Promise<void> {
    if (!(await this.ensureReady())) {
      return;
    }
    if (this.busy) {
      return;
    }
    let room: number = MM_MAX_IMAGES - this.pendingImages.length;
    if (room <= 0) {
      this.notice = Msg.t('m_vm_max_images_prefix') + MM_MAX_IMAGES + Msg.t('m_vm_max_images_suffix');
      return;
    }
    this.busy = true;
    this.error = '';
    try {
      let uris: string[] = await pickImages(room);
      if (uris.length === 0) {
        this.notice = Msg.t('m_vm_no_image');
        return;
      }
      let arr: string[] = this.pendingImages.slice();
      for (let i = 0; i < uris.length; i++) {
        arr.push(uris[i]);
      }
      this.pendingImages = arr;
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.i(TAG, 'pickImages cancelled/failed: %{public}s', e.message);
      this.notice = Msg.t('m_vm_pick_cancelled');
    } finally {
      this.busy = false;
    }
  }

  /** S2-a: remove one pending attachment by uri. */
  removePendingImage(uri: string): void {
    let arr: string[] = this.pendingImages.slice();
    for (let i = arr.length - 1; i >= 0; i--) {
      if (arr[i] === uri) {
        arr.splice(i, 1);
        break;
      }
    }
    this.pendingImages = arr;
  }

  private clearPendingImages(): void {
    this.pendingImages = [];
  }

  /**
   * Send one user message (S2-a: text + optional album images), create
   * a run, stream SSE deltas, then finalize and persist the assistant
   * row on a terminal event.
   *
   * S2-a degradation: image prep runs before any local state change so
   * a total failure leaves no dangling row and the pending row survives
   * for retry. Per-image failure skips the image with a notice; when
   * every image fails the send degrades to text (or aborts when there
   * is no text).
   */
  /** 2026-11-18 提取：新 run 前的状态复位。
   *  把 sendMessage 里散落的 11 项状态清零集中到一处，降低遗漏风险：
   *  - streamText: 流式累积文本（旧 run 残留会污染新 run 显示）
   *  - steps: tool.started/completed 对（transient per run）
   *  - lastSeq: 重订阅去重 gate（-1 = 从头）
   *  - terminalReceived: 终态帧接收标志
   *  - backfill: 一次性重放标志
   *  - terminalSnap: getRun 终态快照
   *  - stopRequested: 停止请求（createRun 前的 pending 停止）
   *  - streamPolls: 旧流守卫位（恒 0；基线轮询为唯一取数通道）
   *  - pollingForResult: UI「正在获取结果」提示
   *  - approval: 审批卡状态
   */
  private resetRunState(): void {
    this.streamText = '';
    this.steps = [];
    this.lastSeq = -1;
    this.terminalReceived = false;
    this.backfill = false;
    this.terminalSnap = null;
    this.stopRequested = false;
    this.streamPolls = 0;
    this.pollingForResult = false;
    this.canReopenRemote = false; // §R3：新 run 清掉上一轮的「重开取回」入口
    this.clearApprovalState();
    this.stopBaselinePoll(); // §R0：新 run 前清掉上一条 ticker，避免两个并存
  }

  // ================= §R0 基线轮询（getRun 为基线，SSE 为增强） =================

  /** §R0-2：建 run 成功即刻开跑，不等 SSE 判死；单一 setInterval ticker 驱动
   *  （嵌套定时器竞速在 ArkTS async 下不可靠——S3-b 前的 recovery 通道即因此废弃）。 */
  private startBaselinePoll(runId: string): void {
    this.stopBaselinePoll(); // 幂等清场：同一时刻只允许一条基线 ticker
    this.baselineRunId = runId;
    this.baselinePollIntervalMs = POLL_START_MS;
    this.baselineLastOutput = '';
    this.baselineIdleRounds = 0;
    this.baselineTextFromSnapshot = false;
    // §R3：新 run 起始必须把三条放弃判据的计数归零，否则上一轮残留
    // 的 failStreak/unknownStreak 会让新一轮第一拍就误判。
    this.failStreak = 0;
    this.unknownStreak = 0;
    this.lastUnknownStatus = '';
    this.baselineStartAt = Date.now(); // §R3 ③：30min 绝对上限的起算点
    this.giveUpDetail = '';
    // P1：等待期计时器，每秒推进「已用时 N 秒」（实测缺陷：一直是 0）。
    this.elapsedSec = 0;
    this.elapsedTimer = setInterval((): void => {
      this.elapsedSec = this.elapsedSec + 1;
      this.notifyUi();
    }, ELAPSED_TICK_MS);
    this.armBaselineTicker();
    LogSafe.i(TAG, 'baseline poll started: runId=%{public}s interval=%{public}dms',
      runId, this.baselinePollIntervalMs);
  }

  /** 按 baselinePollIntervalMs 建/重建 tick 句柄（自适应降频时调用）。 */
  private armBaselineTicker(): void {
    if (this.baselinePollTimer !== -1) {
      clearInterval(this.baselinePollTimer);
      this.baselinePollTimer = -1;
    }
    this.baselinePollTimer = setInterval((): void => {
      this.baselinePollTick();
    }, this.baselinePollIntervalMs);
  }

  /** §R0-3：在飞跳过（同一 run 在飞 getRun ≤1，不排队不叠加）。 */
  private baselinePollTick(): void {
    if (this.baselinePollInFlight) {
      return; // 跳过本轮：绝不并发两个 getRun
    }
    let rid: string = this.baselineRunId;
    if (rid === '') {
      this.stopBaselinePoll();
      return;
    }
    this.baselinePollInFlight = true;
    // async 壳 + try/finally：成功失败都清在飞标志
    this.baselinePollTickAsync(rid).catch((err: Error): void => {
      LogSafe.w(TAG, 'baseline poll tick failed: %{public}s', err.message);
    });
  }

  private async baselinePollTickAsync(rid: string): Promise<void> {
    try {
      await this.baselinePollOnce(rid);
    } finally {
      this.baselinePollInFlight = false; // 无论成功失败都清在飞标志
    }
  }

  /** §R3 单一放弃判据实现点：只看三个事实，不看「等了多久」。
   *  - 连续 getRun 失败达峰 → 连接层断了（run 未必死）；
   *  - 连续未知状态达峰    → 协议层异常（status 原样作诊断码）；
   *  - 绝对上限 30min      → 兜底，run 仍在服务端。
   *  前两条是「事实判据」：status 仍为 active 时两个计数每拍归零，永不触发；
   *  只有第三条绝对上限能在 active 时结束本轮等待（run 仍在服务端）。 */
  private shouldGiveUp(failStreak: number, unknownStreak: number, elapsedMs: number): GiveUpReason {
    return decideGiveUp(failStreak, unknownStreak, elapsedMs);
  }

  /** §R3：reason → finalizeRun 的 how 字串（三层文案一一对应，不混用）。 */
  private giveUpHow(reason: GiveUpReason): string {
    if (reason === GiveUpReason.CONNECTION_LOST) {
      return 'connection-lost';
    }
    if (reason === GiveUpReason.PROTOCOL_ERROR) {
      return 'protocol-error';
    }
    if (reason === GiveUpReason.ABANDONED_REMOTE) {
      return 'abandoned-remote';
    }
    return '';
  }

  /** §R3 收口：判据命中则停轮询 + finalizeRun；未命中返回 false 继续等。
   *  计数与诊断码在 stopBaselinePoll 里归零，所以先抓诊断码再收口。 */
  private checkGiveUp(rid: string): boolean {
    // 防御：轮询已停（stopBaselinePoll 把 baselineRunId/baselineStartAt 清了）
    // 或已切 run 时，本拍的计数不作数——否则 Date.now() - 0 会瞬间命中 30min
    // 绝对上限，对一条已收口的 run 误发 abandoned-remote。
    if (rid === '' || rid !== this.baselineRunId || this.baselineStartAt === 0) {
      return false;
    }
    let reason: GiveUpReason = this.shouldGiveUp(this.failStreak, this.unknownStreak,
      Date.now() - this.baselineStartAt);
    if (reason === GiveUpReason.NONE) {
      return false;
    }
    let how: string = this.giveUpHow(reason);
    LogSafe.w(TAG,
      'baseline poll gave up: how=%{public}s failStreak=%{public}d unknownStreak=%{public}d elapsedMs=%{public}d runId=%{public}s',
      how, this.failStreak, this.unknownStreak, Date.now() - this.baselineStartAt, rid);
    this.giveUpDetail = reason === GiveUpReason.PROTOCOL_ERROR ? this.lastUnknownStatus : '';
    this.stopBaselinePoll();
    this.finalizeRun('', how, false);
    return true;
  }

  /** tick 主体：一次 getRun + 快照归并与自适应降频。
   *  §R3：不再按墙钟放弃——active 就继续等，只由 shouldGiveUp 三条判据收口。 */
  private async baselinePollOnce(rid: string): Promise<void> {
    let snap: RunSnapshot;
    try {
      snap = await this.runs.getRun(rid);
    } catch (err) {
      let e: Error = err as Error;
      // §R3 ①：连接层事实计数（网络断/单次预算超时），不再是静默 return。
      this.failStreak = this.failStreak + 1;
      LogSafe.w(TAG, 'poll#%{public}d t=%{public}dms failed: %{public}s',
        this.pollSeq, Date.now() - this.runStartedAt, e.message);
      LogSafe.d(TAG, 'baseline getRun failed (streak=%{public}d): %{public}s',
        this.failStreak, e.message);
      this.checkGiveUp(rid);
      return; // 未达峰：下一拍再来
    }
    if (rid !== this.baselineRunId) {
      return; // 已切 run：本次结果作废
    }
    let elapsed: number = Date.now() - this.runStartedAt;
    LogSafe.i(TAG, 'poll#%{public}d t=%{public}dms status=%{public}s outLen=%{public}d',
      this.pollSeq, elapsed, snap.status, snap.output.length);
    this.pollSeq = this.pollSeq + 1;
    if (isTerminalStatus(snap.status)) {
      this.stopBaselinePoll();
      this.finalizeRun(snap.output, snap.status !== '' ? snap.status : 'completed', false);
      return;
    }
    if (!isKnownActiveStatus(snap.status)) {
      // §R3 ②：既不在终态集也不在 active 集 = 未知状态，计数并留诊断码。
      this.unknownStreak = this.unknownStreak + 1;
      this.lastUnknownStatus = snap.status;
      LogSafe.w(TAG,
        'baseline poll unknown status=%{public}s (streak=%{public}d) runId=%{public}s',
        snap.status, this.unknownStreak, rid);
      this.checkGiveUp(rid);
      return;
    }
    // §R3：拿到已识别状态（终态已在上方返回 / 此处必为 active）→ 两个计数都归零。
    this.failStreak = 0;
    this.unknownStreak = 0;
    this.lastUnknownStatus = '';
    // S8b：GET /v1/runs/{id} 走 run_projection()，审批在 pending_controls 数组里
    // （不是顶层 approval）。SSE 在本链路不投帧，所以卡片只能靠轮询喂。
    if (snap.status === 'waiting_for_approval' && this.pendingApproval === null) {
      let fromPoll: ApprovalControl | null = null;
      if (snap.pending_controls.length > 0) {
        fromPoll = snap.pending_controls[0];
      } else if (snap.approval !== null) {
        fromPoll = snap.approval;
      }
      if (fromPoll !== null) {
        LogSafe.i(TAG, 'approval card from snapshot: promptId=%{public}s choices=%{public}d',
          fromPoll.prompt_id, fromPoll.choices.length);
        this.setPendingApproval(fromPoll);
      }
    }
    // 非终态：把快照 output 写进当前气泡（复用现有 streamText 渲染入口）。
    if (this.firstDeltaAt === 0 && snap.output.length > 0) {
      this.firstDeltaAt = Date.now();
      LogSafe.i(TAG, 'first delta (poll) t=%{public}dms len=%{public}d',
        this.firstDeltaAt - this.runStartedAt, snap.output.length);
    }
    this.lastOutLen = snap.output.length;
    this.applySnapshotOutput(snap.output);
    // §R0-4 自适应：连续 N 轮 output 无变化 -> 间隔翻倍（封顶见 PollPolicy）。
    if (snap.output === this.baselineLastOutput) {
      this.baselineIdleRounds = this.baselineIdleRounds + 1;
      const next: number = nextPollInterval(this.baselinePollIntervalMs, this.baselineIdleRounds);
      if (next !== this.baselinePollIntervalMs) {
        this.baselinePollIntervalMs = next;
        this.baselineIdleRounds = 0;
        this.armBaselineTicker(); // 重建 interval 使新拍距生效
        LogSafe.i(TAG, 'baseline poll slowed down: interval=%{public}dms',
          this.baselinePollIntervalMs);
      }
    } else {
      this.baselineIdleRounds = 0;
    }
    this.baselineLastOutput = snap.output;
  }

  /** §R0-6：快照 -> 现有气泡渲染入口（前缀差量，不新写渲染）。 */
  private applySnapshotOutput(text: string): void {
    if (text === '' || text.length <= this.streamText.length) {
      return;
    }
    this.streamText = text;
    this.baselineTextFromSnapshot = true;
    this.notifyUi();
  }

  /** 停轮询 + 复位全部 baseline/elapsed 字段（幂等）。 */
  private stopBaselinePoll(): void {
    if (this.baselinePollTimer !== -1) {
      clearInterval(this.baselinePollTimer);
      this.baselinePollTimer = -1;
    }
    if (this.elapsedTimer !== -1) {
      clearInterval(this.elapsedTimer);
      this.elapsedTimer = -1;
    }
    this.baselinePollInFlight = false;
    this.baselineRunId = '';
    this.baselineLastOutput = '';
    this.baselineIdleRounds = 0;
    this.baselineTextFromSnapshot = false;
    // §R3：轮询停即判据计数归零（stopBaselinePoll 是新 run / 终态收口 /
    // 用户停止的共同出口），否则下一轮 run 会被残留计数误判。
    this.failStreak = 0;
    this.unknownStreak = 0;
    this.lastUnknownStatus = '';
    this.baselineStartAt = 0;
    this.elapsedSec = 0;
  }

  async sendMessage(text: string, imageUris: string[]): Promise<void> {
    if (text === '' && imageUris.length === 0) {
      return;
    }
    if (!(await this.ensureReady())) {
      return;
    }
    // S2-b: quote context (引用) — one-shot. Prepend the quoted message
    // (truncated to 200 chars) so the model has context. WYSIWYG: the
    // local bubble and the sent payload carry the same quote+text.
    if (this.quoteContext !== null) {
      let qctx: LocalMessage = this.quoteContext;
      this.quoteContext = null;
      this.notifyUi();
      if (text.trim() !== '' && qctx.content !== '') {
        let q: string = qctx.content;
        if (q.length > 200) {
          q = q.substring(0, 200) + '…';
        }
        text = '> ' + q + '\n\n' + text;
      }
    }
    // P5: slash-command intercept (text-only; image attach -> normal send).
    // Sits BEFORE the busy guard so /stop is usable mid-run; an unknown
    // /xxx is not a command — handleSlashCommand returns false and we fall
    // through to the normal send path (spec: never block '/'-prefixed text).
    if (imageUris.length === 0 && text.trim().charAt(0) === '/') {
      let handled: boolean = await this.handleSlashCommand(text);
      if (handled) {
        return;
      }
    }
    if (this.busy) {
      return;
    }
    if (!this.hasSession) {
      await this.newSession();
      if (!this.hasSession) {
        return;
      }
    }

    this.busy = true;
    this.error = '';
    this.firstDeltaAt = 0;
    this.lastOutLen = 0;
    this.pollSeq = 0;
    // 清掉上一轮的「已收到 N 字」展示位（3 秒窗口按时间差判过期）。
    this.justFinishedMs = -1;
    this.justFinishedChars = 0;
    this.runStartedAt = Date.now();
    this.notifyUi();

    // S2-a: prepare images first (large HEIC can take seconds). input
    // stays the M1 plain string unless at least one image survives.
    let input: Object = text;
    let okUris: string[] = [];
    if (imageUris.length > 0) {
      let dataUrls: string[] = [];
      let skipped: number = 0;
      for (let i = 0; i < imageUris.length; i++) {
        let u: string = imageUris[i];
        try {
          let p: PreparedImage = await prepareImage(u);
          dataUrls.push(p.dataUrl);
          okUris.push(u);
        } catch (err) {
          let e: Error = err as Error;
          LogSafe.w(TAG, 'image prep failed, skipped: %{public}s', e.message);
          skipped++;
        }
      }
      if (dataUrls.length === 0) {
        this.busy = false;
        if (text === '') {
          this.error = Msg.t('m_vm_image_fail');
          return;
        }
        this.notice = Msg.t('m_vm_image_fail_text');
      } else {
        input = buildUserMessage(text, dataUrls);
        if (skipped > 0) {
          this.notice = skipped + Msg.t('m_vm_images_skipped');
        }
      }
    }

    let now: number = Date.now();
    let um: LocalMessage = new LocalMessage();
    um.key = this.activePk;
    um.sessionId = this.activeSessionId;
    um.role = MessageRole.USER;
    um.content = text;
    um.imageUris = okUris;
    um.serverMsgId = 0;
    um.timestamp = now;
    um.createdAt = now;
    let arr: LocalMessage[] = this.messages.slice();
    arr.push(um);
    this.messages = arr;
    this.lastUserMsg = um; // P4⑤: remember for "retry last"

    try {
      await this.db.saveMessages([um]);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'save user message failed: %{public}s', e.message);
      this.busy = false;
      this.error = Msg.t('m_vm_local_save_fail') + e.message;
      return;
    }

    // S9a：标题与 Hermes derive_title 同规则（首个有意义行，≤48 字符按词边界 + …）。
    // 只在还没有标题时写，不覆盖服务端已升级的标题。
    if (this.currentTitle === '' && text !== '') {
      let derived: string = deriveLocalTitle(text);
      if (derived !== '') {
        this.currentTitle = derived;
        try {
          let sess: LocalSession | null = await this.db.getSession(this.activePk);
          if (sess !== null) {
            sess.title = derived;
            sess.updatedAt = now;
            await this.db.upsertSession(sess);
          }
        } catch (err) {
          let e: Error = err as Error;
          LogSafe.w(TAG, 'derive session title failed: %{public}s', e.message);
        }
      }
    }

    // 2026-11-18 提取 resetRunState()：新 run 前的状态复位统一管理，
    // 避免复位逻辑散落（busy/streamText/steps/lastSeq/terminalReceived/
    // backfill/terminalSnap/stopRequested/streamPolls/pollingForResult/
    // approval 都在此一处清零，降低遗漏风险）。
    this.resetRunState();

    try {
      let runId: string = await this.runs.createRun(input, this.activeSessionId);
      this.activeRunId = runId;
      // S2-a: run accepted (202) — the attachment row is consumed
      // whether the run is streamed or stopped-immediately (the
      // message exists server-side either way).
      this.clearPendingImages();
      if (this.stopRequested) {
        // Stop was pressed while the run was being created: stop the
        // run server-side and reset local state (batch2 P1-03 edge).
        this.stopRequested = false;
        this.activeRunId = '';
        this.runs.stop(runId).catch((err: Error): void => {
          LogSafe.w(TAG, 'stop run failed: %{public}s', err.message);
        });
        this.busy = false;
        this.parser = null;
        this.streamText = '';
        this.notice = Msg.t('m_vm_stopped');
        return;
      }
      LogSafe.d(TAG, 'run created: id=%{public}s', runId);
      this.runStartedAt = Date.now();
      this.firstDeltaAt = 0;
      LogSafe.i(TAG, 'run t0: runId=%{public}s', runId);
      // §R0-2：建 run 成功后立刻并行开基线轮询——不等 SSE 判死。实测旧链路
      // 「先等 30s idle + 重试」让用户白等 46.9s，而 getRun 一次就能拿到终态。
      this.startBaselinePoll(runId);
      // S1: unified open path (fresh streams and resubscribes); an
      // open failure is only logged — the baseline poll owns retrieval.
      this.openRunStream();
    } catch (err) {
      let e: Error = err as Error;
      this.busy = false;
      this.parser = null;
      this.activeRunId = '';
      if (this.sessionRequired(e)) {
        this.authMode = 'loggedOut';
        this.dropAuthIdentity();
        this.error = Msg.t('m_vm_login_expired');
        this.notifyUi();
      } else {
        this.error = Msg.t('m_vm_send_fail') + describeError(e);
      }
    }
  }

  /** S2-b: resend a user bubble as a new run. imageUris are re-prepared
   *  by the send pipeline; re-fetched rows carry no uris and resend as
   *  plain text (known limitation, test-target L3-08). */
  resendMessage(m: LocalMessage): void {
    if (m.role !== MessageRole.USER || this.busy || !this.ready) {
      return;
    }
    if (m.content === '' && m.imageUris.length === 0) {
      return;
    }
    this.sendMessage(m.content, m.imageUris.slice());
  }

  /** P4⑤: retry the last user message after a failed send/stream
   *  ("重试上一条"); fall back to reconnect when there is nothing to retry
   *  (e.g. a boot-time connection error with no send attempted yet). */
  retryLastError(): void {
    if (this.busy) {
      return;
    }
    if (this.lastUserMsg !== null) {
      this.resendMessage(this.lastUserMsg);
    } else {
      this.connect();
    }
  }

  /** S2-b: copy a bubble to the system pasteboard (notice on success,
   *  error on failure — clipboard access can be denied). */
  async copyText(text: string): Promise<void> {
    if (text === '') {
      return;
    }
    try {
      let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      let pb: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await pb.setData(data);
      this.notice = Msg.t('m_vm_copied');
      LogSafe.i(TAG, 'copied to pasteboard: %{public}d chars', text.length);
    } catch (err) {
      let e: Error = err as Error;
      this.error = Msg.t('m_vm_copy_fail') + e.message;
      LogSafe.w(TAG, 'copy failed: %{public}s', e.message);
    }
  }

  /** S2-b: 引用 — set the quote context (the message being replied to).
   *  One-shot: consumed by the next sendMessage (prepended as context).
   *  The page shows a "回复中" bar above the input while set. */
  quoteMessage(m: LocalMessage): void {
    this.quoteContext = m;
    this.notifyUi();
  }

  /** S2-b: clear the quote context (the ✕ on the "回复中" bar). */
  clearQuote(): void {
    this.quoteContext = null;
    this.notifyUi();
  }

  /** S2-b: 删除 — remove one message from the in-memory list (by object
   *  reference, since in-memory-created messages may not yet carry a DB
   *  rowid) + the DB row when a rowid is present (loaded messages). The
   *  gateway has no delete endpoint, so server-sourced copies may reappear
   *  on the next refetch; local-only copies reappear only if still cached. */
  async deleteMessage(m: LocalMessage): Promise<void> {
    this.messages = this.messages.filter((x: LocalMessage): boolean => x !== m);
    if (m.id > 0) {
      try {
        await this.db.deleteMessage(m.id);
      } catch (err) {
        let e: Error = err as Error;
        this.error = Msg.t('m_vm_delete_fail') + e.message;
      }
    }
    this.notifyUi();
  }

  // ================= S2-c: voice input (on-device ASR) =================
  //
  // Zero-dependency route (plan §4.1): the gateway API surface accepts
  // image parts only (capabilities audio_api:false; session_api_media is
  // image_url-only), so speech is recognized ON-DEVICE via CoreSpeechKit
  // speechRecognizer. Official V13 constraints: zh-CN only, offline model
  // only (online:1, no network), recognitionMode 0 = the engine captures
  // the mic itself (no AVRecorder/PCM buffer). VAD auto-terminates the
  // round (10s leading silence / 0.8s trailing / 30s cap, D4). D2: one
  // engine per round. D3: final text fills the input field; the user
  // confirms the send. Engine methods are sync (void); async failures
  // surface via the listener's onError.
  //
  // Engine lifecycle (D2): createEngine -> setListener -> startListening
  // -> (onComplete | onError | finish | cancel) -> shutdown. The one-shot
  // voiceEnded guard keeps the finalize+shutdown pair idempotent even if
  // both onComplete and a late onError arrive.

  /** S2-c: request MICROPHONE (user_grant) and start one ASR round. */
  async startVoice(onFinalText: (text: string) => void): Promise<void> {
    if (this.busy || this.voiceState !== 'idle') {
      return;
    }
    this.voiceOnFinal = onFinalText;
    // ohos.permission.MICROPHONE is user_grant: ask at runtime before
    // the engine starts listening (declared in module.json5).
    let atMgr: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    // PermissionRequestResult is not exported by name in this SDK;
    // infer the result type (same pattern as ScanVM.startScan).
    let grant = await atMgr.requestPermissionsFromUser(this.ctx, ['ohos.permission.MICROPHONE']);
    if (grant.authResults.length === 0 || grant.authResults[0] !== 0) {
      this.error = Msg.t('m_vm_mic_perm');
      return;
    }
    let engine: speechRecognizer.SpeechRecognitionEngine | null = null;
    try {
      // online:1 = offline mode (only mode supported, no network).
      let extraParams: Record<string, Object> = { 'locate': 'CN', 'recognizerMode': 'short' };
      let params: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1,
        extraParams: extraParams
      };
      engine = await speechRecognizer.createEngine(params);
      this.asrEngine = engine;
      this.voiceAccum = '';
      this.voiceDiscarded = false;
      this.voiceEnded = false;
      this.voicePartial = '';
      this.voiceState = 'listening';
      let listener: speechRecognizer.RecognitionListener = {
        onStart: (sessionId: string, eventMessage: string): void => {
          LogSafe.i(TAG, 'ASR start session=%{public}s', sessionId);
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
          LogSafe.d(TAG, 'ASR event code=%{public}d', eventCode);
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          // Per-clause results: isFinal = clause settled; isLast marks
          // the final clause of the round.
          if (result.isFinal) {
            this.voiceAccum += result.result;
          }
          this.voicePartial = this.voiceAccum + result.result;
        },
        onComplete: (sessionId: string, eventMessage: string): void => {
          this.onVoiceEnd();
        },
        onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
          this.onVoiceError(errorCode, errorMessage);
        }
      };
      engine.setListener(listener);
      this.voiceSessionId = 'voice-' + Date.now().toString(36) +
        Math.floor(Math.random() * 1000000).toString(36);
      // recognitionMode:0 = the engine captures the mic itself (needs
      // ohos.permission.MICROPHONE); VAD auto-terminates (0.8s trailing
      // silence / 10s leading silence / 30s hard cap, D4).
      let startExtra: Record<string, Object> = {
        'recognitionMode': 0,
        'vadBegin': 10000,
        'vadEnd': 800,
        'maxAudioDuration': 30000
      };
      let startParams: speechRecognizer.StartParams = {
        sessionId: this.voiceSessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, sampleBit: 16, soundChannel: 1 },
        extraParams: startExtra
      };
      // Sync call: a startup failure surfaces via the listener's onError
      // (e.g. 1002200002), not a returned promise.
      engine.startListening(startParams);
      LogSafe.i(TAG, 'ASR listening started');
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'startVoice failed: %{public}s', e.message);
      this.error = Msg.t('m_vm_voice_start_fail') + e.message;
      this.voiceState = 'idle';
      this.voicePartial = '';
      if (engine !== null) {
        this.asrEngine = null;
        this.releaseEngine(engine);
      }
    }
  }

  /** S2-c: adopt the round (⏹): the engine finalizes; the settled text
   *  arrives via onComplete -> onVoiceEnd. */
  finishVoice(): void {
    let engine: speechRecognizer.SpeechRecognitionEngine | null = this.asrEngine;
    if (this.voiceState !== 'listening' || engine === null) {
      return;
    }
    try {
      engine.finish(this.voiceSessionId);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'ASR finish failed: %{public}s', e.message);
      this.onVoiceError(-1, e.message);
    }
  }

  /** S2-c: discard the round (✕): cancel the engine; the settled text
   *  is dropped (voiceDiscarded guards the delivery). */
  cancelVoice(): void {
    let engine: speechRecognizer.SpeechRecognitionEngine | null = this.asrEngine;
    if (this.voiceState !== 'listening' || engine === null) {
      return;
    }
    this.voiceDiscarded = true;
    try {
      engine.cancel(this.voiceSessionId);
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'ASR cancel failed: %{public}s', e.message);
      // Still reset: the round is over and the text is discarded.
      this.onVoiceEnd();
    }
  }

  /** S2-c: one-shot round end (onComplete / error / 30s cap): deliver
   *  the settled text (unless discarded), reset the state, release the
   *  engine (D2 per-round lifecycle). */
  private onVoiceEnd(): void {
    if (this.voiceEnded) {
      return;
    }
    this.voiceEnded = true;
    if (!this.voiceDiscarded) {
      let text: string = this.voiceAccum.trim();
      if (text !== '') {
        this.notice = Msg.t('m_vm_voice_done');
        this.voiceOnFinal(text);
      } else {
        this.notice = Msg.t('m_vm_voice_empty');
      }
    }
    this.voiceState = 'idle';
    this.voicePartial = '';
    this.shutdownAsr();
  }

  /** S2-c: listener error (1002200002 start / 1002200004 finish /
   *  1002200005 cancel / 1002200006 busy / ...) or a sync throw
   *  (code -1). */
  private onVoiceError(code: number, msg: string): void {
    if (this.voiceEnded) {
      return;
    }
    this.voiceEnded = true;
    if (!this.voiceDiscarded) {
      // P3-03 修：按错误码分流。录音超长（1002200003 等 ASR 过长/超时类）给精准提示，
      // 避免误导成"网络/Token 问题"；其余保留通用文案 + 原始 message。
      if (isVoiceTooLongCode(code)) {
        this.error = Msg.t('m_vm_voice_too_long');
      } else {
        this.error = Msg.t('m_vm_voice_fail_prefix') + String(code) + '）：' + msg;
      }
    }
    this.voiceState = 'idle';
    this.voicePartial = '';
    this.shutdownAsr();
  }

  /** S2-c: release the round's engine (idempotent). */
  private shutdownAsr(): void {
    let engine: speechRecognizer.SpeechRecognitionEngine | null = this.asrEngine;
    this.asrEngine = null;
    if (engine !== null) {
      this.releaseEngine(engine);
    }
  }

  /** S2-c: shutdown is a sync call; never let it throw out of a
   *  listener or catch path. */
  private releaseEngine(engine: speechRecognizer.SpeechRecognitionEngine): void {
    try {
      engine.shutdown();
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'ASR shutdown failed: %{public}s', e.message);
    }
  }

  private onChunk(chunk: ArrayBuffer): void {
    if (this.parser === null) {
      return;
    }
    if (this.firstDeltaAt === 0) {
      this.firstDeltaAt = Date.now();
      LogSafe.i(TAG, 'first delta t=%{public}dms bytes=%{public}d',
        this.firstDeltaAt - this.runStartedAt, chunk.byteLength);
    }
    // 流真正吐数据 = 流是活的：复位旧流守卫位（S3-b 后恒 0，保留幂等复位）。
    if (this.streamPolls > 0) {
      LogSafe.i(TAG, 'stream resumed delivering data; clearing getRun poll fallback (was %{public}d)', this.streamPolls);
      this.streamPolls = 0;
      this.pollingForResult = false; // 2026-11-18: stream alive again -> hide "fetching" hint
    }
    let evs: SseEvent[] = this.parser.feed(chunk);
    for (let i = 0; i < evs.length; i++) {
      this.handleEvent(evs[i]);
    }
  }

  private handleEvent(ev: SseEvent): void {
    let d: Record<string, Object> | null = ev.data;
    // S1: seq tracking for the resubscribe dedupe gate (mirrors the
    // parser's internal monotonic gate; read at openRunStream).
    if (d !== null) {
      let seq: number = numFrom(d['seq']);
      if (seq > this.lastSeq) {
        this.lastSeq = seq;
      }
    }
    if (ev.event === 'message.delta') {
      if (d !== null) {
        let delta: string = strFrom(d['delta']);
        if (delta !== '') {
          // §R0-5：SSE 一旦真的吐 delta -> 渲染仍交给增量，基线降频到 10s 只做对账。
          if (this.baselinePollTimer !== -1
              && this.baselinePollIntervalMs < POLL_SSE_ACTIVE_MS) {
            this.baselinePollIntervalMs = POLL_SSE_ACTIVE_MS;
            this.armBaselineTicker();
            LogSafe.i(TAG, 'SSE delivering deltas -> baseline poll slowed to %{public}dms (reconcile only)',
              this.baselinePollIntervalMs);
          }
          // §R0-6：气泡文本若已由快照写入，服务端从 seq 0 重放的 delta 可能
          // 重复已有尾部——这种情况下跳过；其余照常追加。仍复用同一个
          // streamText 渲染入口，不新写一套渲染。
          let isReplayTail: boolean = this.baselineTextFromSnapshot && this.streamText.endsWith(delta);
          if (!isReplayTail) {
            this.streamText += delta;
            this.notifyUi();
          }
        }
      }
    } else if (ev.event === 'tool.started') {
      this.upsertStep(d !== null ? strFrom(d['tool_call_id']) : '',
        d !== null ? strFrom(d['tool']) : '',
        d !== null ? strFrom(d['preview']) : '');
    } else if (ev.event === 'tool.completed') {
      this.completeStep(d !== null ? strFrom(d['tool_call_id']) : '',
        d !== null ? numFrom(d['duration']) : 0,
        d !== null ? boolFrom(d['error']) : false);
    } else if (ev.event === 'approval.request' && d !== null) {
      // S1: approval card (D2). Field set matches pending_controls
      // entries (evidence/sse-run3-20261029125336.jsonl).
      this.setPendingApproval(parseApprovalControl(d));
    } else if (ev.event === 'approval.settled') {
      // Server resolved the approval (our POST or a timeout).
      // Polling is the truth: confirm now instead of waiting 5s.
      this.approvalPollTick().catch((err: Error): void => {
        LogSafe.w(TAG, 'settled tick error: %{public}s', err.message);
      });
    } else if (isTerminalSseEvent(ev)) {
      let out: string = d !== null ? strFrom(d['output']) : '';
      this.finalizeRun(out, ev.event.replace('run.', ''), false);
    }
    // Unknown events are ignored.
  }

  /**
   * Finalize the current run: persist the assistant row, drop the
   * request, flip busy, clear all S1 run-scoped state.
   *
   * @param out         server output text (full text on
   *                    run.completed; partial/empty otherwise)
   * @param how         terminal kind: completed / failed / cancelled /
   *                    interrupted / stopped / incomplete / connection-lost /
   *                    protocol-error / abandoned-remote（§R3：三层放弃原因
   *                    各有独立文案，不再共用 recovery-timeout）
   * @param userStopped true when the terminal is a local user stop
   *                    (no run.* event ever arrived); shown as a
   *                    dismissible notice, not an error (batch2 P1-03)
   */
  private finalizeRun(out: string, how: string, userStopped: boolean): void {
    if (this.terminalReceived) {
      return;
    }
    this.terminalReceived = true;
    this.streamPolls = 0; // 旧流守卫位（S3-b 后恒 0，收口时幂等复位）
    this.pollingForResult = false; // 2026-11-18: run done -> hide "fetching" hint
    // S1: server output is the full text; prefer it over the partial
    // local accumulation (snapshot/backfill paths).
    let finalText: string = out !== '' ? out : this.streamText;
    this.streamText = '';
    let totalMs: number = Date.now() - this.runStartedAt;
    let firstDeltaMs: number = this.firstDeltaAt === 0 ? -1 : this.firstDeltaAt - this.runStartedAt;
    LogSafe.i(TAG, 'finalize how=%{public}s finalLength=%{public}d total=%{public}dms firstDelta=%{public}dms',
      how, finalText.length, totalMs, firstDeltaMs);
    // 展示用：收口时刻 + 正文字数（3 秒「已收到」提示，靠时间差判过期）。
    this.justFinishedMs = Date.now();
    this.justFinishedChars = finalText.length;

    if (finalText !== '') {
      let now: number = Date.now();
      let am: LocalMessage = new LocalMessage();
      am.key = this.activePk;
      am.sessionId = this.activeSessionId;
      am.role = MessageRole.ASSISTANT;
      // BUG-001: the gateway's output merges the reasoning preamble and
      // the reply. Split them so the preamble renders collapsed instead of
      // as a wall of text in the bubble.
      let parts: string[] = splitThinking(finalText);
      am.thinking = parts[0];
      am.content = parts[1];
      am.serverMsgId = 0;
      am.timestamp = now;
      am.createdAt = now;
      am.elapsedMs = Date.now() - this.runStartedAt;
      am.firstDeltaMs = this.firstDeltaAt === 0 ? -1 : this.firstDeltaAt - this.runStartedAt;
      // Replace the array reference so the ForEach re-diffs and the
      // new row actually renders (batch2 P0-B).
      let arr: LocalMessage[] = this.messages.slice();
      arr.push(am);
      this.messages = arr;
      this.notifyUi();
      // Fire-and-forget persistence; this callback must stay sync.
      this.db.saveMessages([am]).catch((err: Error): void => {
        this.notice = Msg.t('m_vm_assistant_save_fail');
        LogSafe.w(TAG, 'persist assistant failed: %{public}s', err.message);
      });
      // Bump the session timestamp without returning a promise from then().
      this.db.getSession(this.activePk).then((sess: LocalSession | null): void => {
        if (sess !== null) {
          sess.updatedAt = now;
          this.db.upsertSession(sess).catch((err: Error): void => {
            LogSafe.w(TAG, 'touch session failed: %{public}s', err.message);
          });
        }
      }).catch((err: Error): void => {
        LogSafe.w(TAG, 'read session for touch failed: %{public}s', err.message);
      });
    }

    if (how !== 'completed') {
      if (userStopped) {
        this.notice = Msg.t('m_vm_stopped') + (out === '' ? '' : '：' + out);
      } else if (how === 'connection-lost') {
        // §R3 ①：连接层断了（不是 run 失败）——不得出现「失败」字样。
        this.error = Msg.t('m_vm_interrupted_polling');
      } else if (how === 'protocol-error') {
        // §R3 ②：附诊断码（把那个未知 status 原样带上）。
        let code: string = this.giveUpDetail;
        this.error = Msg.t('m_vm_bad_status')
          + (code === '' ? '' : Msg.t('m_vm_diag_prefix') + code + '）');
      } else if (how === 'abandoned-remote') {
        // §R3 ③：客户端不再等，但 run 仍在服务端——给「重开取回」入口状态位。
        this.canReopenRemote = true;
        this.error = Msg.t('m_vm_interrupted_remote');
      } else if (how === 'incomplete') {
        // Conduit 借鉴：模型跑超步数预算但仍有部分答案——展示已生成内容
        // + 温和提示，而非报错。用户能看到大部分回复。
        this.notice = finalText !== ''
          ? Msg.t('m_vm_partial_steps')
          : Msg.t('m_vm_steps_exhausted');
        LogSafe.i(TAG, 'finalize incomplete: showing partial answer (len=%{public}d)', finalText.length);
      } else {
        this.error = Msg.t('m_vm_run') + how + '：' + (out === '' ? Msg.t('m_vm_see_gateway_log') : out);
      }
    }
    this.busy = false;
    this.parser = null;
    this.activeRunId = '';
    this.steps = [];
    this.notifyUi();
    this.backfill = false;
    this.terminalSnap = null;
    this.clearApprovalState();
    // §R0-2 收口：finalizeRun 是唯一终态出口，基线轮询/计时器必须在此停。
    this.stopBaselinePoll();
    // Converge every terminal path on a single destroy (idempotent;
    // batch2 P1-04).
    this.destroyStream();
    // S9a：收口后异步补一次服务端标题（可能已被 llm 升级）。
    // 不 await：不拖慢收口；方法内部全 catch，不会产生未处理拒绝。
    this.syncTitlesFromServer();
  }

  private onStreamEnd(code: number): void {
    LogSafe.d(TAG, 'stream ended: code=%{public}d', code);
    if (this.parser !== null) {
      let evs: SseEvent[] = this.parser.finish();
      for (let i = 0; i < evs.length; i++) {
        this.handleEvent(evs[i]);
      }
    }
    if (!this.terminalReceived && this.busy) {
      if (this.activeRunId !== '') {
        if (this.backfill) {
          // Replay of a terminal run ended without a terminal frame
          // (server no longer replays): finalize from the snapshot.
          let snap: RunSnapshot | null = this.terminalSnap;
          let how: string = (snap !== null && snap.status !== '') ? snap.status : 'completed';
          this.finalizeRun(snap !== null ? snap.output : '', how, false);
        } else {
          // Durable run: the stream ending is not the run ending. The
          // baseline poll is the only retrieval channel (S3-b: the old
          // recovery loop was removed), so just leave it running.
          LogSafe.d(TAG, 'stream ended; baseline poll remains the only channel; runId=%{public}s',
            this.activeRunId);
        }
      } else if (this.streamText !== '') {
        this.finalizeRun(this.streamText, 'completed', false);
      } else {
        this.busy = false;
        this.parser = null;
      }
    }
    this.destroyStream();
  }

  private onStreamError(err: ApiError): void {
    // Conduit 借鉴：错误分类（stream_drop/auth/timeout/server_error/unknown），
    // 不同分类走不同处理策略 + UI 文案。
    let kind: StreamErrorKind = classifyStreamError(err);
    LogSafe.w(TAG, 'stream error: kind=%{public}s code=%{public}d msg=%{public}s',
      kind, err.code, err.message);
    // BUG-005: destroy the stream BEFORE any further handling.
    this.destroyStream();
    if (this.suspended) {
      return;
    }
    // §R0-5 SSE 语义降级：基线轮询已在跑（baselinePollTimer !== -1）时，流错误
    // 只记日志 / 不重订阅——结果由基线轮询负责取回，SSE 只是增强。
    if (this.baselinePollTimer !== -1) {
      LogSafe.d(TAG,
        'stream error ignored (baseline poll active): kind=%{public}s code=%{public}d',
        kind, err.code);
      return;
    }
    // 旧流守卫（streamPolls>0）：流已被判定静默、streamGen 已递增。此时旧流的
    // SDK readTimeout（destroy 不能彻底取消鸿蒙 SDK 内部定时器）仍会触发本回调，
    // 一律忽略（仅 debug 日志）——取数完全交给基线 getRun 轮询，流已无关紧要。
    if (this.streamPolls > 0) {
      LogSafe.d(TAG,
        'stream error ignored (poll mode active, stream already superseded): kind=%{public}s code=%{public}d',
        kind, err.code);
      return;
    }
    if (this.busy && !this.terminalReceived && this.activeRunId !== '') {
      // S1: the run is durable server-side. A transport error is not a
      // terminal event — the baseline poll keeps retrieving the result
      // (S3-b: no recovery loop any more). 按分类记日志（便于排查）。
      if (kind === StreamErrorKind.AUTH) {
        LogSafe.w(TAG, 'stream error AUTH: token expired; baseline poll continues with the current token');
      } else if (kind === StreamErrorKind.STREAM_DROP) {
        LogSafe.i(TAG, 'stream error STREAM_DROP: baseline poll continues (lastSeq=%{public}d)',
          this.lastSeq);
      }
    } else if (this.busy && !this.terminalReceived) {
      // 无 activeRunId 的错误：按分类显示精准文案
      this.error = Msg.t('m_vm_stream_error') + describeStreamError(kind);
      this.busy = false;
      this.parser = null;
    }
    // 2026-11-18 清理：原此处有第二次 destroyStream() 调用（冗余——1359 行已
    // destroy 并置 streamReq=null），删除。
  }

  /**
   * Best-effort stop: destroy the request, ask the gateway to stop
   * the run, and finalize local state so the UI never sticks on a
   * dead stream (batch2 P1-03). S1: the page confirms first.
   */
  stopStream(): void {
    this.stopRequested = true;
    this.clearApprovalState();
    // §R0-2：用户主动停止必须同时停基线轮询与计时器（否则 run 已停、tick 还在跑）。
    this.stopBaselinePoll();
    this.destroyStream();
    let hadRun: boolean = this.activeRunId !== '';
    if (hadRun) {
      let rid: string = this.activeRunId;
      this.activeRunId = '';
      this.runs.stop(rid).catch((err: Error): void => {
        LogSafe.w(TAG, 'stop run failed: %{public}s', err.message);
      });
    }
    if (this.busy && !this.terminalReceived && (hadRun || this.streamText !== '')) {
      // No terminal event ever arrived (stream died or was cut):
      // finalize locally as a user stop so busy/streamText reset and
      // the partial text is preserved (M1: user stop = cancelled).
      this.finalizeRun(this.streamText, 'cancelled', true);
    }
  }

  clearNotice(): void {
    this.notice = '';
  }

  /** E3: dismiss the green "已连接" success bar. */
  clearSuccess(): void {
    if (this.successTimerId !== -1) {
      clearTimeout(this.successTimerId);
      this.successTimerId = -1;
    }
    this.success = '';
    this.notifyUi();
  }

  // ================= S1: step flow =================

  /** tool.started: add or replace a step keyed by tool_call_id. */
  private upsertStep(toolCallId: string, tool: string, preview: string): void {
    let next: ToolStep[] = [];
    for (let i = 0; i < this.steps.length; i++) {
      let s: ToolStep = this.steps[i];
      if (toolCallId !== '' && s.toolCallId === toolCallId) {
        continue; // replaced below
      }
      next.push(s);
    }
    let st: ToolStep = new ToolStep();
    st.toolCallId = toolCallId;
    st.tool = tool;
    st.preview = preview;
    st.durationSec = -1;
    st.state = 'running';
    next.push(st);
    // Replace the reference so the page's ForEach re-diffs.
    this.steps = next;
  }

  /** tool.completed: fill duration/outcome on the matching step. */
  private completeStep(toolCallId: string, durationSec: number, error: boolean): void {
    let next: ToolStep[] = [];
    for (let i = 0; i < this.steps.length; i++) {
      let s: ToolStep = this.steps[i];
      if (toolCallId !== '' && s.toolCallId === toolCallId) {
        s.state = error ? 'error' : 'ok';
        s.durationSec = durationSec;
      }
      next.push(s);
    }
    this.steps = next;
  }

  // ================= S1: approval card (D2) =================

  private setPendingApproval(req: ApprovalControl): void {
    this.pendingApproval = req;
    this.notifyUi();
    this.approvalActed = false;
    this.approvalDeadline = Date.now() + APPROVAL_TIMEOUT_SEC * 1000;
    this.approvalCountdownSec = APPROVAL_TIMEOUT_SEC;
    this.startApprovalCountdown();
    this.startApprovalPolling();
  }

  private clearApprovalState(): void {
    this.pendingApproval = null;
    this.notifyUi();
    this.approvalCountdownSec = 0;
    this.stopApprovalCountdown();
    this.stopApprovalPolling();
  }

  /** Display-only countdown (D2: hardcoded 60s; polling is the truth). */
  private startApprovalCountdown(): void {
    this.stopApprovalCountdown();
    this.countdownId = setInterval((): void => {
      let remain: number = Math.ceil((this.approvalDeadline - Date.now()) / 1000);
      this.approvalCountdownSec = remain > 0 ? remain : 0;
    }, COUNTDOWN_TICK_MS);
  }

  private stopApprovalCountdown(): void {
    if (this.countdownId !== -1) {
      clearInterval(this.countdownId);
      this.countdownId = -1;
    }
  }

  private startApprovalPolling(): void {
    this.stopApprovalPolling();
    this.approvalPollId = setInterval((): void => {
      this.approvalPollTick().catch((err: Error): void => {
        LogSafe.w(TAG, 'approval poll tick error: %{public}s', err.message);
      });
    }, APPROVAL_POLL_MS);
  }

  private stopApprovalPolling(): void {
    if (this.approvalPollId !== -1) {
      clearInterval(this.approvalPollId);
      this.approvalPollId = -1;
    }
  }

  /** 5s status poll — the only source of truth for approval state (D2).
   *  When the run leaves waiting_for_approval without our decision,
   *  the server auto-denied (timeout). */
  private async approvalPollTick(): Promise<void> {
    if (this.pendingApproval === null || this.activeRunId === '') {
      this.clearApprovalState();
      return;
    }
    try {
      let snap: RunSnapshot = await this.runs.getRun(this.activeRunId);
      if (snap.status !== 'waiting_for_approval') {
        if (this.approvalActed) {
          // Our decision was accepted; the run continues or ends.
          this.clearApprovalState();
        } else {
          this.clearApprovalState();
          this.notice = Msg.t('m_vm_approval_timeout');
        }
      }
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'approval poll: getRun failed: %{public}s', e.message);
    }
  }

  /** Submit one of the four approval choices (page button). */
  async submitApproval(choice: string): Promise<void> {
    let req: ApprovalControl | null = this.pendingApproval;
    if (req === null || this.activeRunId === '' || this.approvalActed) {
      return;
    }
    this.approvalActed = true;
    try {
      await this.runs.approve(this.activeRunId, req.prompt_id, req.execution_generation, choice);
      this.clearApprovalState();
      this.notice = choice === 'deny' ? Msg.t('m_vm_approval_denied') : Msg.t('m_vm_approval_ok_prefix') + this.choiceLabel(choice) + '）';
    } catch (err) {
      let e: Error = err as Error;
      this.error = Msg.t('m_vm_approval_fail') + describeError(e);
      // Pull the truth immediately instead of waiting the next 5s tick.
      this.approvalPollTick().catch((err2: Error): void => {
        LogSafe.w(TAG, 'post-fail tick error: %{public}s', err2.message);
      });
    }
  }

  private choiceLabel(choice: string): string {
    if (choice === 'once') {
      return Msg.t('m_vm_choice_once');
    }
    if (choice === 'session') {
      return Msg.t('m_vm_choice_session');
    }
    if (choice === 'always') {
      return Msg.t('m_vm_choice_always');
    }
    return Msg.t('m_vm_choice_deny');
  }

  // ================= S1: steer =================

  /** /steer: interject into the running run without stopping it. */
  async sendSteer(text: string): Promise<void> {
    if (!(await this.ensureReady())) {
      return;
    }
    if (!this.busy || this.activeRunId === '') {
      this.error = Msg.t('m_vm_no_running');
      return;
    }
    try {
      let ok: boolean = await this.runs.steer(this.activeRunId, text);
      if (ok) {
        this.notice = Msg.t('m_vm_steer_ok');
      } else {
        this.error = Msg.t('m_vm_steer_rejected');
      }
    } catch (err) {
      let e: Error = err as Error;
      this.error = Msg.t('m_vm_steer_fail') + describeError(e);
    }
  }

  // ================= P5: slash commands =================
  // Client-side /xxx -> API mapping (single source of truth in
  // net/SlashCommands.ets). Intercepted in sendMessage AFTER ensureReady
  // and BEFORE the busy guard so /stop works mid-run; an unknown /xxx
  // returns false and falls through to the normal send path (spec: never
  // block legitimate '/'-prefixed content). Results surface as transient
  // system bubbles (MessageRole.SYSTEM), never user/assistant bubbles.

  private sysSeq: number = 0;

  /** P5: append a transient system bubble (slash-command feedback).
   *  In-memory only (NOT persisted, not conversation history); cleared on
   *  session switch / refetch because this.messages is replaced there.
   *  Negative id keeps the render key unique (server ids are positive). */
  private appendSystemMessage(text: string): void {
    this.sysSeq = this.sysSeq + 1;
    let sm: LocalMessage = new LocalMessage();
    sm.id = -this.sysSeq;
    sm.key = this.activePk;
    sm.sessionId = this.activeSessionId;
    sm.role = MessageRole.SYSTEM;
    sm.content = text;
    sm.serverMsgId = 0;
    sm.timestamp = Date.now();
    sm.createdAt = Date.now();
    let arr: LocalMessage[] = this.messages.slice();
    arr.push(sm);
    this.messages = arr;
    this.notifyUi();
  }

  /** P5: intercept a slash command. Returns true when the text was
   *  consumed (a mapped command executed, or "not supported" surfaced);
   *  false when it is an unknown /xxx (caller falls through to send). */
  private async handleSlashCommand(text: string): Promise<boolean> {
    let name: string = slashName(text);
    let cmd: SlashCommand | null = findCommand(name);
    if (cmd !== null) {
      let arg: string = slashArg(text);
      if (name === '/new') {
        await this.handleCmdNew();
      } else if (name === '/resume') {
        await this.handleCmdResume(arg);
      } else if (name === '/title') {
        await this.handleCmdTitle(arg);
      } else if (name === '/stop') {
        await this.handleCmdStop();
      } else if (name === '/approve') {
        await this.handleCmdApprove(arg);
      }
      return true;
    }
    if (isKnownUnmapped(name)) {
      this.appendSystemMessage(Msg.t('m_vm_unsupported_prefix') + name);
      return true;
    }
    return false;
  }

  /** P5 /new: new session; busy guard surfaces an explicit hint. */
  private async handleCmdNew(): Promise<void> {
    if (this.busy) {
      this.appendSystemMessage(Msg.t('m_vm_busy_switch'));
      return;
    }
    await this.newSession();
    if (this.hasSession) {
      this.appendSystemMessage(Msg.t('m_vm_new_ok'));
    }
  }

  /** P5 /resume [index|keyword]: no arg lists recent sessions (numbered,
   *  last_active desc); an arg switches by 1-based index or title keyword
   *  via the existing takeover path. */
  private async handleCmdResume(arg: string): Promise<void> {
    if (this.busy) {
      this.appendSystemMessage(Msg.t('m_vm_busy_no_switch'));
      return;
    }
    try {
      await this.listServerSessions();
      let rows: MergedSession[] = this.mergedSessions();
      let keep: MergedSession[] = [];
      for (let i: number = 0; i < rows.length; i++) {
        if (rows[i].messageCount > 0) {
          keep.push(rows[i]);
        }
      }
      if (arg === '') {
        let n: number = keep.length < 10 ? keep.length : 10;
        if (n === 0) {
          this.appendSystemMessage(Msg.t('m_vm_no_history'));
          return;
        }
        let lines: string[] = [];
        for (let j: number = 0; j < n; j++) {
          lines.push(String(j + 1) + '. ' + keep[j].title);
        }
        this.appendSystemMessage(Msg.t('m_vm_resume_list') + lines.join('\n'));
        return;
      }
      let target: MergedSession | null = null;
      let idx: number = parseInt(arg);
      if (!isNaN(idx) && idx >= 1 && idx <= keep.length) {
        target = keep[idx - 1];
      } else {
        let kw: string = arg.toLowerCase();
        for (let k: number = 0; k < keep.length; k++) {
          if (keep[k].title.toLowerCase().indexOf(kw) >= 0) {
            target = keep[k];
            break;
          }
        }
      }
      if (target === null) {
        this.appendSystemMessage(Msg.t('m_vm_no_match'));
        return;
      }
      let t2: MergedSession = target;
      let nm: string = fallbackTitle(t2.title, t2.sessionId);
      await this.takeoverSession(t2.sessionId, nm);
      this.appendSystemMessage(Msg.t('m_vm_switched_prefix') + nm + '」');
    } catch (err) {
      let e: Error = err as Error;
      this.appendSystemMessage(Msg.t('m_vm_switch_fail') + describeError(e));
    }
  }

  /** P5 /title [newTitle]: no arg shows the current title; an arg renames
   *  via PATCH /api/sessions/{id} + local row sync + sidebar refresh. */
  private async handleCmdTitle(arg: string): Promise<void> {
    if (!this.hasSession) {
      this.appendSystemMessage(Msg.t('m_vm_no_active'));
      return;
    }
    if (arg === '') {
      this.appendSystemMessage(Msg.t('m_vm_current_title') + this.currentTitle);
      return;
    }
    try {
      await this.sessionsApi.setTitle(this.activeSessionId, arg);
      let sess: LocalSession | null = await this.db.getSession(this.activePk);
      if (sess !== null) {
        sess.title = arg;
        sess.updatedAt = Date.now();
        await this.db.upsertSession(sess);
      }
      await this.listLocalSessions();
      this.currentTitle = arg;
      this.appendSystemMessage(Msg.t('m_vm_renamed_prefix') + arg + '」');
    } catch (err) {
      let e: Error = err as Error;
      this.appendSystemMessage(Msg.t('m_vm_rename_fail') + describeError(e));
    }
  }

  /** P5 /stop: reuse the existing stopStream() (stopRequested + destroy +
   *  runs.stop + cancel finalize) — one cancel mechanism, not a new one. */
  private async handleCmdStop(): Promise<void> {
    if (!this.busy || this.activeRunId === '') {
      this.appendSystemMessage(Msg.t('m_vm_no_run'));
      return;
    }
    this.stopStream();
    this.appendSystemMessage(Msg.t('m_vm_stopped_short'));
  }

  /** P5 /approve <choice>: validate the choice against the pending
   *  approval's choices, then reuse the existing submitApproval() path. */
  private async handleCmdApprove(arg: string): Promise<void> {
    let req: ApprovalControl | null = this.pendingApproval;
    if (req === null || this.activeRunId === '') {
      this.appendSystemMessage(Msg.t('m_vm_no_pending_approval'));
      return;
    }
    if (arg === '') {
      this.appendSystemMessage(Msg.t('m_vm_specify_option') + req.choices.join(' / '));
      return;
    }
    let valid: boolean = false;
    for (let i = 0; i < req.choices.length; i++) {
      if (req.choices[i] === arg) {
        valid = true;
        break;
      }
    }
    if (!valid) {
      this.appendSystemMessage(Msg.t('m_vm_invalid_option') + req.choices.join(' / '));
      return;
    }
    await this.submitApproval(arg);
  }

  // ================= S1: server sessions takeover =================

  /** S1: GET /api/sessions for the takeover panel (R-05 evidence:
   *  {data:[{id,title,preview,last_active,message_count,...}]}). */
  async listServerSessions(): Promise<void> {
    if (!(await this.ensureReady())) {
      return;
    }
    this.serverSessionsLoading = true;
    try {
      this.serverSessions = await this.store.listServer();
      await this.syncTitlesFromServer();
    } catch (err) {
      let e: Error = err as Error;
      if (this.sessionRequired(e)) {
        this.authMode = 'loggedOut';
        this.dropAuthIdentity();
        this.error = Msg.t('m_vm_login_expired');
        this.notifyUi();
      } else {
        this.error = Msg.t('m_vm_read_server_fail') + describeError(e);
      }
    }
    this.serverSessionsLoading = false;
  }

  /** S9a：把服务端权威标题回写到本地行（服务端可能已把派生名升级为 llm 短标题）。
   *  内部全 catch，永不上抛；由 listServerSessions 与 finalizeRun 触发。 */
  async syncTitlesFromServer(): Promise<void> {
    try {
      if (this.serverSessions.length === 0) {
        this.serverSessions = await this.store.listServer();
      }
      let r: TitleSync = await this.store.applyServerTitles(this.serverSessions, this.activePk);
      if (r.changed) {
        if (r.activeTitle !== '') {
          this.currentTitle = r.activeTitle;
        }
        await this.listLocalSessions();
        this.notifyUi();
      }
    } catch (err) {
      let e: Error = err as Error;
      LogSafe.w(TAG, 'syncTitlesFromServer failed: %{public}s', e.message);
    }
  }

  /** S9a：统一会话列表（本地行判定「本地」，服务端补齐其余「服务端」）。UI 只渲染这个。 */
  mergedSessions(): MergedSession[] {
    return this.store.merged(this.sessions, this.serverSessions);
  }

  /** S9a-2b：删除会话 —— 先删服务端（404 视为已删），成功后再删本地行；
   *  409（会话有任务在跑）保留本地行并提示先停止；pk 为空的「仅服务端」行也能删。 */
  async deleteSession(pk: string, sessionId: string): Promise<void> {
    if (!(await this.ensureReady())) {
      return;
    }
    if (pk !== '' && this.busy && this.activePk === pk) {
      this.error = Msg.t('m_vm_active_no_delete');
      this.notifyUi();
      return;
    }
    let out = await this.store.remove(pk, sessionId);
    if (!out.ok) {
      if (out.authExpired) {
        this.authMode = 'loggedOut';
        this.dropAuthIdentity();
      }
      this.error = out.message;
      this.notifyUi();
      return;
    }
    if (pk !== '' && this.activePk === pk) {
      this.activePk = '';
      this.activeSessionId = '';
      this.currentTitle = '';
      this.hasSession = false;
      this.messages = [];
      this.streamText = '';
    }
    await this.listLocalSessions();
    try {
      this.serverSessions = await this.store.listServer();
    } catch (err) {
      LogSafe.w(TAG, 'deleteSession: refresh server list failed: %{public}s', (err as Error).message);
    }
    this.notifyUi();
  }

  /** S1: 接手 — open a server session; if this device has never seen
   *  it, create the local row first (quadruple pk is deterministic),
   *  then run the standard openSession path (local-first + refetch). */
  async takeoverSession(id: string, title: string): Promise<void> {
    if (!this.ready || this.busy) {
      return;
    }
    try {
      let pk: string = await this.store.ensureLocalRow(id, title);
      await this.openSession(pk);
    } catch (err) {
      this.error = Msg.t('m_vm_takeover_fail') + describeError(err as Error);
    }
  }

  // ================= S1: background / foreground lifecycle =================

  /** App entered background: keep the run, destroy the stream.
   *  Timers freeze with the process; all run state survives.
   *
   *  Conduit 借鉴（background_streaming_handler.dart）：iOS/Android 用前台
   *  service 保活，但鸿蒙移动端策略不同——直接 destroy stream。服务端 run 是
   *  持久 的（durable），App 侧只需在回前台时补数据：基线 getRun 轮询是唯一
   *  取数通道，回前台后它照常把终态取回。后台保活（backgroundTaskManager）
   *  增加复杂度和电量消耗，跨机场景下 SSE 本身就不稳定，不值得。 */
  suspendForBackground(): void {
    if (!this.busy) {
      return;
    }
    this.suspended = true;
    this.destroyStream();
    LogSafe.i(TAG, 'suspended for background; run=%{public}s lastSeq=%{public}d',
      this.activeRunId, this.lastSeq);
  }

  /** App returned to foreground: the baseline poll (still armed) keeps
   *  retrieving any in-flight run; nothing to re-arm here. */
  resumeFromBackground(): void {
    if (!this.suspended) {
      return;
    }
    this.suspended = false;
    if (this.busy && !this.terminalReceived && this.activeRunId !== '') {
      LogSafe.d(TAG, 'resumed; baseline poll remains the only channel for run=%{public}s',
        this.activeRunId);
    }
    if (this.pendingApproval !== null) {
      // Restart the timers frozen in the background; the deadline is
      // absolute, so the countdown recomputes from real time.
      this.startApprovalCountdown();
      this.startApprovalPolling();
    }
  }

  /**
   * Open (or re-open) the run's SSE stream. Every open bumps the
   * generation; callbacks from destroyed (stale) requests are dropped.
   * The parser is recreated with its seq gate at lastSeq so a server
   * replay (from seq 0) does not re-apply already-applied frames.
   */
  private openRunStream(): void {
    let rid: string = this.activeRunId;
    if (rid === '') {
      return;
    }
    this.destroyStream();
    this.parser = new SseParser();
    this.parser.gateSeq(this.lastSeq);
    let gen: number = this.streamGen + 1;
    this.streamGen = gen;
    // Conduit 借鉴：重连时带 Last-Event-ID（lastSeq），服务端重放漏帧恢复逐字输出。
    // 新流 lastSeq=-1 不带 header；断线重连 lastSeq>=0 带 header 从 lastSeq+1 补发。
    let p: Promise<http.HttpRequest | null> = this.runs.openEvents(rid,
      (chunk: ArrayBuffer): void => {
        if (gen !== this.streamGen) {
          return;
        }
        this.onChunk(chunk);
      },
      (code: number): void => {
        if (gen !== this.streamGen) {
          return;
        }
        this.onStreamEnd(code);
      },
      (err: ApiError): void => {
        if (gen !== this.streamGen) {
          return;
        }
        this.onStreamError(err);
      }, this.lastSeq);
    p.then((req: http.HttpRequest | null): void => {
      if (gen !== this.streamGen) {
        return;
      }
      this.streamReq = req;
      if (req === null) {
        this.onStreamOpenFailed();
      }
    }).catch((err: Error): void => {
      if (gen !== this.streamGen) {
        return;
      }
      LogSafe.w(TAG, 'openEvents failed: %{public}s', err.message);
      this.onStreamOpenFailed();
    });
  }

  /** The (re)open of the event stream failed: backfill finalizes from the
   *  snapshot (the server no longer serves the replay); otherwise nothing
   *  to do — SSE is an enhancement only and the baseline poll keeps
   *  retrieving the run (S3-b: no recovery loop any more). */
  private onStreamOpenFailed(): void {
    if (this.backfill && this.terminalSnap !== null) {
      let snap: RunSnapshot = this.terminalSnap;
      this.finalizeRun(snap.output, snap.status !== '' ? snap.status : 'completed', false);
      return;
    }
    LogSafe.w(TAG, 'openEvents failed: baseline poll remains the only channel');
  }

  /** Destroy the current HTTP request, never throwing from a callback. */
  private destroyStream(): void {
    if (this.streamReq !== null) {
      let req: http.HttpRequest = this.streamReq;
      this.streamReq = null;
      try {
        // S5a: 走 RunsApi 透传的静默取消——req.destroy() 停不掉闭包里的
        // SSE 空闲看门狗（terminated/idleTimerId），30s 后仍会 finishError。
        this.runs.cancelEvents(req);
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        LogSafe.w(TAG, 'destroy stream failed: code=%{public}d message=%{public}s',
          e.code, String(e.message));
      }
    }
  }
}

/** JSON Object -> string (null/undefined safe). */
function strFrom(v: Object | null | undefined): string {
  if (v === null || v === undefined) {
    return '';
  }
  return String(v);
}

/** JSON Object -> number (NaN/missing -> 0). */
function numFrom(v: Object | null | undefined): number {
  if (v === null || v === undefined) {
    return 0;
  }
  let n: number = Number(v);
  return Number.isNaN(n) ? 0 : n;
}
