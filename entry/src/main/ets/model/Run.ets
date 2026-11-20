// =====================================================================
// model/Run.ets — run 状态与快照（M1 流式会话；M2 审批卡在此扩展）
//
// 契约基准（tools/api-selftest.py 全绿实证，2026-10-27）：
//   POST /v1/runs            -> 202 {run_id}
//   GET  /v1/runs/{id}       -> {status, output, execution_generation, pending_controls[], ...}
//   POST /v1/runs/{id}/stop  -> 200/202（W-03f）
//   POST /v1/runs/{id}/steer -> 200 {accepted: true}（W-03c，body {input}）
//   POST /v1/runs/{id}/approval -> body {request_id, execution_generation, choice}（A 组）
//   GET  /v1/runs/{id}/events    -> SSE（data 帧 JSON，事件名在载荷 "event" 字段）
// 终态集合：completed / failed / cancelled / interrupted（selftest TERMINAL）
// =====================================================================

import { BusinessError } from '@kit.BasicServicesKit';
import { LogSafe } from '../utils/LogSafe';
import { strFrom, numFrom } from './ChatMessage';

const TAG: string = 'Run';

export enum RunStatus {
  PENDING = 'pending',
  RUNNING = 'running',
  WAITING_APPROVAL = 'waiting_for_approval',
  // S2fix：网关还有 5 个**非终态**字面量，此前枚举里没有 → ChatVM 的 active
  // 白名单无处引用它们，queued/claimed/stopping 连续 3 拍（~6s）就被判成
  // 「未知状态 = 协议异常」收口。值一律取网关字面量（不是自造拼写）。
  // 证据 gateway/platforms/api_server_runs.py：
  //   queued  = 新建 run 的初始状态（_set_run_status(..., "queued", ...) :857/:910）
  //   claimed = 被 worker 领走的中间态（record["status"] in ("queued","claimed") :1043）
  //   scheduled = 排队中
  //   stopping = 用户 stop 后、终态前的过渡态（_stopping_run_ids :273/:1109）
  //   finalizing = 收尾中
  QUEUED = 'queued',
  CLAIMED = 'claimed',
  SCHEDULED = 'scheduled',
  STOPPING = 'stopping',
  FINALIZING = 'finalizing',
  COMPLETED = 'completed',
  FAILED = 'failed',
  CANCELLED = 'cancelled',
  // Conduit 借鉴：服务端 stop 后的终态（用户点"停止"后 run 变 stopped）。
  // 此前漏判 → 点停止后 recovery 仍按非终态继续轮询/卡住。
  STOPPED = 'stopped',
  INTERRUPTED = 'interrupted',
  // Conduit 借鉴：模型跑超步数预算时的终态。仍有部分答案可用，
  // 不是失败——UI 应展示已生成内容 + "回复可能不完整"提示。
  INCOMPLETE = 'incomplete'
}

/** 终态判定（selftest TERMINAL 集合 + Conduit 借鉴补 stopped / canceled / incomplete） */
export function isTerminalStatus(status: string): boolean {
  return status === RunStatus.COMPLETED
    || status === RunStatus.FAILED
    || status === RunStatus.CANCELLED
    || status === RunStatus.STOPPED
    || status === RunStatus.INTERRUPTED
    || status === RunStatus.INCOMPLETE
    // 防御：canceled 是 cancelled 的美式拼写变体（Conduit 兼容两者）。
    || status === 'canceled';
}

/** Conduit 借鉴：判断是否为 incomplete（跑超预算但仍有部分答案）。
 *  UI 应展示已生成内容 + 温和提示，而非报错。 */
export function isIncompleteStatus(status: string): boolean {
  return status === RunStatus.INCOMPLETE;
}

/** 审批控制条目（A-5 实证：GET /v1/runs/{id} 暴露 pending_controls） */
export interface ApprovalControl {
  kind: string;
  prompt_id: string;
  execution_generation: number;
  command: string;
  description: string;
  choices: string[];
}

/** Run 状态快照（execution_generation 为顶层字段，selftest W-02b:368） */
export interface RunSnapshot {
  run_id: string;
  status: string;
  output: string;
  execution_generation: number;
  pending_controls: ApprovalControl[];
  /** S8a：网关在 waiting_for_approval 时给的审批载荷（SSE 不投帧，靠轮询喂卡片）。 */
  approval: ApprovalControl | null;
}

/** 宽容解析 GET /v1/runs/{id} 响应（缺字段取默认值，不抛错） */
export function parseRunSnapshot(body: string, runId: string): RunSnapshot {
  let snap: RunSnapshot = {
    run_id: runId,
    status: '',
    output: '',
    execution_generation: 0,
    pending_controls: [],
    approval: null
  };
  try {
    let d: Record<string, Object> = JSON.parse(body);
    let st: Object | null | undefined = d['status'];
    if (st !== null && st !== undefined) {
      snap.status = String(st);
    }
    let out: Object | null | undefined = d['output'];
    if (out !== null && out !== undefined) {
      snap.output = String(out);
    }
    let gen: Object | null | undefined = d['execution_generation'];
    if (gen !== null && gen !== undefined) {
      snap.execution_generation = numFrom(gen);
    }
    let pc: Object | null | undefined = d['pending_controls'];
    if (pc !== null && pc !== undefined && pc instanceof Array) {
      snap.pending_controls = parseControls(pc);
    }
    // S8a：网关把审批放在顶层 「approval」（不是 pending_controls）。
    let ap: Object | null | undefined = d['approval'];
    if (ap !== null && ap !== undefined && !(ap instanceof Array)) {
      let apRec: Record<string, Object> = ap as Record<string, Object>;
      let ac: ApprovalControl = parseApprovalControl(apRec);
      if (ac.kind === '') {
        ac.kind = 'approval';
      }
      // 网关载荷用 request_id，ApprovalControl 用 prompt_id：补齐映射
      if (ac.prompt_id === '') {
        ac.prompt_id = strFrom(apRec['request_id']);
      }
      // 载荷未给 choices 时用 A-5 的四选项默认值
      if (ac.choices.length === 0) {
        ac.choices = ['once', 'session', 'always', 'deny'];
      }
      snap.approval = ac;
    }
  } catch (err) {
    let e: BusinessError = err as BusinessError;
    LogSafe.w(TAG, 'run snapshot parse failed, lenient: %{public}s', String(e.message));
  }
  return snap;
}

/**
 * 从 approval.request SSE 载荷解析审批控制项（S1）。
 * 字段集与 pending_controls 条目一致（evidence/sse-run3-20261029125336.jsonl：
 * kind/prompt_id/execution_generation/command/description/choices）。
 */
export function parseApprovalControl(d: Record<string, Object>): ApprovalControl {
  return {
    kind: strFrom(d['kind']),
    prompt_id: strFrom(d['prompt_id']),
    execution_generation: numFrom(d['execution_generation']),
    command: strFrom(d['command']),
    description: strFrom(d['description']),
    choices: parseChoices(d['choices'])
  };
}

/** 解析 pending_controls 数组（instanceof 先收窄再逐字段转换，P2-05） */
function parseControls(pc: Object): ApprovalControl[] {
  let raw: Record<string, Object>[] = pc as Record<string, Object>[];
  let out: ApprovalControl[] = [];
  for (let i = 0; i < raw.length; i++) {
    let c: Record<string, Object> = raw[i];
    let ac: ApprovalControl = {
      kind: strFrom(c['kind']),
      prompt_id: strFrom(c['prompt_id']),
      execution_generation: numFrom(c['execution_generation']),
      command: strFrom(c['command']),
      description: strFrom(c['description']),
      choices: parseChoices(c['choices'])
    };
    out.push(ac);
  }
  return out;
}

/** 解析 choices 字符串数组（instanceof 先收窄，P2-05） */
function parseChoices(v: Object | null | undefined): string[] {
  let out: string[] = [];
  if (v === null || v === undefined || !(v instanceof Array)) {
    return out;
  }
  let raw: string[] = v as string[];
  for (let i = 0; i < raw.length; i++) {
    out.push(raw[i]);
  }
  return out;
}
