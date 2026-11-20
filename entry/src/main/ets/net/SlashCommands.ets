// =====================================================================
// net/SlashCommands.ets — P5 斜杠命令映射表（单一事实源）
// EN: Slash-command mapping table (single source of truth). The REST surface does not dispatch commands,
//
// 背景（P5 核心约束，源自 §9 斜杠命令映射）：
//   网关原生命令集（/new /resume /sessions /branch /title /save /undo
//   /retry /topic /compress，gateway/slash_commands_session.py）仅对走
//   消息管道的 surface（CLI、企微/Telegram）生效；APP 的 REST API 面
//   （POST /api/sessions/{id}/chat -> _run_agent）不经命令分发——输入
//   /xxx 会被当普通消息发给模型，APP 退化为纯聊天。
//   对策：APP 输入框识别 / 开头命令并拦截，转成等价 API 调用。
//
// 映射目标 = 已实证的 API 端点，不是原生命令名（解耦，防网关升级腐烂）：
//   原生命令集改名/增删不自动波及本表；新增原生命令只有当 APP 需要暴露
//   给它时加一条（前提：有对应 API 端点，否则标 CLI-only）。
//
// 单一事实源：命令->端点映射只存在于此文件，设计文档只引用；
//   漂移检测自测（tools/slash-selftest.py）对本表逐条目探端点
//   （期望结构化 4xx 而非 404），网关升级移除/改名端点时自测变红。
//   新增命令 = 加一条目 + 自测一条，无第二份要同步。
//
// method 用字符串（'POST'/'GET'/'PATCH'）而非 http.RequestMethod 枚举：
//   枚举在当前构建工具链存在解析不确定性（BUG-002 同源教训），字符串
//   仅供自测探端点与文档参考，客户端分派按 name 命中，不依赖 method。
// =====================================================================

/** 一条斜杠命令映射（命令名 -> API 端点 + 说明）。 */
export interface SlashCommand {
  name: string;        // '/new'（精确命令名，含前导 /）
  method: string;      // 'POST' | 'GET' | 'PATCH'（漂移自测探端点用）
  path: string;        // '/api/sessions' 或 '/v1/runs/{id}/stop'（{id} 由自测填测试 id）
  descKey: string;     // i18n key（app.string.slash_<name>_desc），命令提示 UI 用
}

/** P1 核心映射表（5 条；6 端点 2026-11-17 B 轮复审逐一核实：
 *  POST /api/sessions、GET /api/sessions、GET /api/sessions/{id}/messages、
 *  POST /v1/runs/{id}/stop、POST /v1/runs/{id}/approval 五条真实请求实证；
 *  PATCH /api/sessions/{id} 网关代码实证存在（api_server.py 路由+handler），
 *  真实请求待 T2 补齐——漂移自测对 6 端点逐条探活。 */
export const SLASH_COMMANDS: SlashCommand[] = [
  { name: '/new', method: 'POST', path: '/api/sessions', descKey: 'app.string.slash_new_desc' },
  { name: '/resume', method: 'GET', path: '/api/sessions', descKey: 'app.string.slash_resume_desc' },
  { name: '/title', method: 'PATCH', path: '/api/sessions/{id}', descKey: 'app.string.slash_title_desc' },
  { name: '/stop', method: 'POST', path: '/v1/runs/{id}/stop', descKey: 'app.string.slash_stop_desc' },
  { name: '/approve', method: 'POST', path: '/v1/runs/{id}/approval', descKey: 'app.string.slash_approve_desc' }
];

/** 原生 10 命令中未映射的 7 条（无对应 API 端点，APP 内显式提示「当前不支持」，
 *  系统气泡，不发模型）。 */
export const KNOWN_UNMAPPED: string[] = [
  '/branch', '/save', '/undo', '/retry', '/topic', '/compress', '/sessions'
];

/**
 * 取 /xxx 的裸命令名（不含参数）：'/resume 2' -> '/resume'；
 *  非 / 开头或空 -> ''。trim 后再判，避免尾随空格干扰。
 */
export function slashName(text: string): string {
  let t: string = text.trim();
  if (t.length === 0 || t.charAt(0) !== '/') {
    return '';
  }
  let sp: number = t.indexOf(' ');
  if (sp < 0) {
    return t;
  }
  return t.substring(0, sp);
}

/**
 * 取 /xxx 的参数部分（trim，可能为空）：'/title 我的' -> '我的'；
 *  '/new' -> ''；非 / 开头 -> ''。
 */
export function slashArg(text: string): string {
  let t: string = text.trim();
  if (t.length === 0 || t.charAt(0) !== '/') {
    return '';
  }
  let sp: number = t.indexOf(' ');
  if (sp < 0) {
    return '';
  }
  return t.substring(sp + 1).trim();
}

/** 匹配核心映射表（精确命令名；命中返回条目，否则 null）。 */
export function findCommand(name: string): SlashCommand | null {
  for (let i = 0; i < SLASH_COMMANDS.length; i++) {
    if (SLASH_COMMANDS[i].name === name) {
      return SLASH_COMMANDS[i];
    }
  }
  return null;
}

/** 是否已知未映射命令（提示「当前不支持」，不发模型）。 */
export function isKnownUnmapped(name: string): boolean {
  for (let i = 0; i < KNOWN_UNMAPPED.length; i++) {
    if (KNOWN_UNMAPPED[i] === name) {
      return true;
    }
  }
  return false;
}
