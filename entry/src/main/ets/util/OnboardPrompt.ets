// =====================================================================
// util/OnboardPrompt.ets — S1.5 Delegation-First onboarding prompt
// builder (plan v2.6 §4.8; v2.6.6 goal-oriented template, single tier).
//
// Builds the prompt the user pastes into their own Hermes conversation
// (CLI / WeCom / Web — channel-agnostic). The prompt is GOAL-ORIENTED:
// it states WHAT must be true (the target ready state), not HOW — no
// script commands, no flags, no file paths beyond the agreed QR drop
// location. The Hermes agent decides the steps itself.
//
// v2.6.6 (2026-11-16, 主控 decision): single tier QR only — no
// admin/user split; single tier = single profile (default): the prompt
// pins the default configuration and reports-and-stops if it is absent
// (template item 1; multi-profile access = open issue, --profile held
// by 主控 2026-11-16). The prompt carries NO secrets (no IP / port /
// key): the agent self-detects addresses and self-checks the token.
//
// SINGLE SOURCE OF TRUTH = plan §4.8 (v2 goal-oriented template).
// Two code copies:
//   1. this file (App side, ArkTS)
//   2. tools/hermes-paw-qr cmd_prompt (server side, Python)
// They MUST stay byte-for-byte identical for the same name input
// (acceptance S1.5-d, tools/s15-selftest.py check_sync). Change one,
// change the other.
//
// Zero dependencies: pure string construction, no network / permission.
// =====================================================================

/**
 * Build the goal-oriented onboarding prompt (v2.6.6, single tier).
 *
 * @param name  optional profile display name; empty omits the name
 *              line (the agent then names the profile itself).
 * @returns     the prompt text to paste into the Hermes conversation.
 */
export function buildOnboardPrompt(name: string): string {
  const lines: string[] = [];
  lines.push('请帮我完成本机（运行 Hermes 网关的这台机器）的 HermesPaw 手机接入配置。目标：');
  if (name !== '') {
    lines.push('档案显示名："' + name + '"。');
  }
  lines.push('1. 使用本机 Hermes 网关的 default 配置（默认 profile）；若不存在，报告并停下；');
  lines.push('2. 该配置的 API server 处于就绪状态：已启用、监听办公网络（非本机回环）、持有长效连接 key；若已就绪，核对后跳过；');
  lines.push('3. 生成 HermesPaw 接入二维码（hermespaw:// 配置串，单一档码），存到 /tmp/hermespaw-qr.png；');
  lines.push('4. 把图片文件 /tmp/hermespaw-qr.png 发给我；若当前通道无法发图片，改把 hermespaw:// 配置串贴到对话里（该文本含长效 key，仅可信通道发送、勿转发）；');
  lines.push('5. 若中途预检不通过（如 API server 不可达、无 key），报告具体原因与处置办法，不要出码；若需要重启网关，把重启命令告诉我，我重启完成后再继续；');
  lines.push('6. 我扫码完成后，提醒我删除 /tmp/hermespaw-qr.png。');
  return lines.join('\n');
}
