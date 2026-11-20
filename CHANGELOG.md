# 变更记录

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 重构

- 会话面板抽成 `pages/chat/SessionPanel.ets`（@Component）：`ChatPage` 79,017 → 74,807 B，
  `build()` 1001 → 899 行；数据单向流入、6 个回调回写父页 @State，面板不持有 ChatVM
- 真机验证记录见 `docs/impl-status.md` §2.17（语音模块 ASR 日志、面板开关/长按/取消）
- 审批卡抽成 `pages/chat/ApprovalCard.ets`：`ChatPage` 74,807 → 72,692 B，
  `build()` 899 → 836 行；真机验证见 `docs/impl-status.md` §2.18（四按钮同行、拒绝后卡片消失）
- 状态条与登录闸门抽成 `pages/chat/StatusBar.ets` / `pages/chat/LoginGate.ets`：
  `ChatPage` 72,692 → 71,454 B，`build()` 836 → 796 行；状态条真机验到秒数与动画点同步刷新，
  登录闸门仅静态等价校验（触发需退登录，`docs/impl-status.md` §2.19 写明口径）

## [0.1.1] — 2026-11-20

这一版没有新增用户可见功能，全部是「让别人敢用、让项目能维护」的东西。

### 新增

- `CONTRIBUTING.md`：环境要求、三种检查怎么跑、设备测试步骤、六条硬性代码规则、PR 需要附什么证据
- `SECURITY.md`：先讲安全模型（只内网 / key 只进安全存储 / 审批默认拒绝 / 零依赖），再给私密上报渠道
- `.github/`：Issue 表单（bug / feature）、PR 模板、`config.yml`（禁空 Issue + 三条引导链接）
- `.github/workflows/selftest.yml`：在 Ubuntu + Python 3.12 上跑 `make test` / `lint` / `scan`
- `docs/channel-comparison.md`：与企微、个人微信通道的十项对比，每条标了网关源码位置
- `docs/README.md` / `docs/README.en.md`：文档索引（每篇回答什么、给谁看、是否仍为准）
- `docs/promo/`：推广稿与发布清单
- `docs/impl-status.md` §2.15 / §2.16：getRun 差分测量的证据补录、会话删除守卫的真机实测

### 变更

- 中英文案全面 i18n 化：206 处硬编码中文收口到 `Msg.t`，三套 `string.json` 各 345 个键
- 会话面板支持搜索、本地/服务端统一空会话过滤、空标题兜底为「未命名 · id 后 6 位」

### 修复

- `make test` 把退出码 77 当失败的问题：需要网关的两组用例（`api-selftest` / `s2-selftest`）在无
  `API_SERVER_KEY` 时按约定 SKIP，现在识别为 `SKIP` 并单独计数，不再误判为红

### 重构

- 语音识别整块（8 个字段 + 7 个方法）移到 `viewmodel/VoiceInput.ets`：`ChatVM` 99,016 → 90,781 B，
  相对 102,400 B 闸门的余量从 3,384 B 恢复到 11,619 B；`ChatPage` 零改动（保留三个薄壳 + 两个只读投影）

### 文档

- 技术文《给 Hermes Agent 写一个鸿蒙客户端：审批、插话，和被放弃的流式输出》在华为开发者社区发布
  （2026-11-20，链接记录在 `docs/promo/PUBLISH.md`）

## [0.1.0] — 2026-11-20

首个公开发布。

### 新增

- HarmonyOS NEXT 原生客户端：纯 ArkTS，零第三方运行时依赖，单个 HAP
- 传输策略：`getRun` 轮询为基线、SSE 仅作增强（网关 REST 面不推增量帧）
- 审批卡片：四个选项 + 60 秒倒计时，超时默认拒绝（批准 / 拒绝 / 超时三条路径真机实测）
- `/steer` 插话、停止、run 状态三态与消息时间戳
- 会话列表：本地 + 服务端合并、搜索、长按删除（服务端 409 守卫）、服务端自动命名回同步
- 图片输入（长边 1568 / JPEG q80）、端侧语音识别
- 中英双语界面、六种强调色、多网关扫码接入

### 已知限制

- 只在同一局域网内工作，不做公网中继、不经过第三方 IM
- 没有后台推送，靠前台轮询
- 做不到逐字流式上屏（网关不推增量，客户端拿不到）

[0.1.1]: https://github.com/pzmmy/hermes-paw/releases/tag/v0.1.1
[0.1.0]: https://github.com/pzmmy/hermes-paw/releases/tag/v0.1.0
