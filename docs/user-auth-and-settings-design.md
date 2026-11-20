# 用户登录与设置扩展 — 设计规格（P1 已回退 / P2 休眠 / P3 精简实施）

> 状态：**D6 选项 B 裁定（2026-11-17 主控）**：邮箱验证码登录**不启用**——P1 网关已回退（删模块 + 摘 3 接线点，`/api/auth/*` 恢复 404，回放包 `gateway-patches/p1-auth/` 留存）；P2 客户端代码保留休眠（探针 404 → legacy 模式，零行为变化）；P3 按精简范围已实施（2026-11-18 完成，`03e1200`：关于 + 开源信息 + key 状态只读，登录依赖行不做）。重新启用路径 = 回放 P1 + 配 `auth.email.*` + 网关重启。
> 历史：P1 网关 2026-11-17 实施（`tools/auth-selftest.py` 26/26 通过）；P2 客户端 2026-11-17 实施（commits `5c064c4`+`2871e33`，L2 五件套 5/5 绿）——均于 2026-11-17 依 D6 回退/休眠；P3 精简版 2026-11-18 实施（`03e1200`，L2 五件套 5/5 绿）。本文件为该特性的设计规格 + 决策记录 + 实施状态。
> 范围：**邮箱验证码登录**（用户身份，注册即登录、无密码；**D6 裁定不启用**）+ **设置页四节**（精简实施：关于 / 开源信息 / key 状态只读，见 §10）。
> 约定：正文为中文设计口径；接口 / 字段 / 配置名用英文 verbatim。不含任何凭据。

## TL;DR — 决策状态（D1–D5 已裁定，D6 选项 B 已裁定 2026-11-17）

| # | 决策 | 裁定 | 影响面 |
|---|---|---|---|
| **D1** | 会话 token 与网关 Bearer key（`API_SERVER_KEY`）的关系 | **裁定：A 解耦叠加**（key = 设备凭证，会话 = 身份凭证，数据面二者并存） | 数据面鉴权路径，**最关键** |
| **D2** | 账号存储位置 | **裁定：独立 `account.db`**（与 state.db 隔离） | 网关存储 |
| **D3** | 未登录态能否用数据面 | **裁定：强制登录**（无有效会话禁数据面） | 登录强制性，**存量数据面调用方破坏性变更** |
| **D4** | 邮箱是否为唯一身份 | **裁定：是**（`display_name` 可空可后改） | 账号模型 |
| **D5** | SMTP 凭据命名空间 | **已按默认建议实施（P1）**：独立 `auth.email.*`，fail-closed（随 P1 回退，配置项无代码消费） | 配置 |
| **D6** | 是否启用邮箱验证码登录 | **裁定：选项 B 不启用**（2026-11-17 主控：短期无多用户计划、免 SMTP 依赖；安全基线 = 设备 key（服务端）+ 手机锁屏/APP 锁（客户端）） | P1 回退、P2 休眠、P3 精简；**逆转 D3 强制登录的生效**（数据面回到仅设备 key 单凭证） |

## 1. 背景与动机

当前 HermesPaw **无用户账号体系**：客户端经 QR 码持有网关 Bearer key（`API_SERVER_KEY`），数据面以该 key 鉴权（见 README §安全、`docs/test-target-s1.md` T2），**无 per-user 身份**。本特性引入用户账号 + 邮箱验证码登录，目标：

1. **per-user 身份**：同一网关可承载多用户，各自独立会话与身份归因。
2. **跨设备账号持久化**：换机登录同一邮箱即恢复用户态（与现有档案 / 会话持久化正交）。
3. **无密码**：注册即登录（邮箱 + 验证码），无密码可泄露、无「找回密码」需求。

## 2. 范围界定

| 本期范围 | 不在本期 |
|---|---|
| 邮箱验证码登录（注册即登录） | 密码 / 短信 / 社交登录 |
| 会话管理（签发 / 吊销 / 滑动 TTL） | 多因素 MFA / 设备指纹绑定 |
| 设置四节：用户信息 / 安全信息 / 关于 / 开源信息 | 子账号 / 团队空间 / 角色权限 |
| 网关 `/api/auth/*` + 账号/码/会话存储 + SMTP 出站 | 富媒体邮件（纯文本邮件即可） |
| 强制登录闸门（D3）：数据面无有效会话返回 401 | 匿名数据面（key only） |

## 3. 架构落点

- **网关侧**（hermes-agent，Python）：新增 `/api/auth/*` 族 + 账号/码/会话存储（`gateway/platforms/api_server_auth.py`）+ SMTP **纯出站**发送（懒加载复用 `plugins/platforms/email/adapter.py` 的 `_open_smtp`/`_tls_context`/IPv4 强制 helper，插件不可用时回退 stdlib `smtplib`，不引入整个平台适配器）。
- **客户端侧**（HermesPaw，ArkTS）：登录页（未登录态入口）+ 会话存储（`store/TokenVault.ets`，HUKS AES-256-GCM）+ 设置四节 UI + 数据面请求附会话凭证。
- **存储**：账号/码/会话入独立 `account.db`（D2 已裁定），与 `state.db` 分文件。

## 4. 数据模型（网关 SQLite）

```
users(
  id            INTEGER PK,
  email         TEXT UNIQUE NOT NULL,      -- 小写规范化
  display_name  TEXT,                       -- 可空
  status        TEXT NOT NULL DEFAULT 'active',  -- active | disabled
  created_at    INTEGER,                    -- epoch ms
  last_login_at INTEGER
)

verify_codes(
  id           INTEGER PK,
  email        TEXT NOT NULL,
  code_hash    TEXT NOT NULL,               -- SHA-256(6 位码)，不存明文
  purpose      TEXT NOT NULL DEFAULT 'login',   -- login | change_email
  expires_at   INTEGER NOT NULL,            -- 签发 + 5min
  consumed_at  INTEGER,                     -- 成功校验置位（单次使用）
  attempts     INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL
)

sessions(
  id           INTEGER PK,
  user_id      INTEGER NOT NULL REFERENCES users(id),
  token_hash   TEXT NOT NULL UNIQUE,        -- SHA-256(会话 token)
  device_label TEXT,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,            -- 滑动 TTL，上限 30d
  last_seen_at INTEGER
)
```

**D2 已裁定：以上 3 表均入独立 `account.db`** — 与 `state.db` 分文件；此处的 `sessions` 表指用户认证会话，非 state.db 的会话（对话）表。

## 5. 关键决策（裁定记录，2026-11-17）

**D1 会话 token 与网关 Bearer key 的关系**（架构核心）— **裁定：A 解耦叠加**。
`API_SERVER_KEY` 仍为「设备↔网关」凭证（QR 流程不变）；会话 token 为「用户身份」凭证。登录后数据面请求**同时**携带二者（`Authorization: Bearer <key>` + `X-User-Session: <token>`）。
> 落选：**B 替换**（会话 token 接管数据面、key 退化为 bootstrap — 改现有鉴权路径回归面大）；**C 仅身份层**（数据面仍只认 key — 数据面无 per-user 归因）。

**D2 账号存储** — **裁定：独立 `account.db`**（独立 SQLite 文件，活动 profile home 根下）。
users / verify_codes / sessions 三表均入 account.db（活动 profile home 根，即 `get_hermes_home()`；随 profile 作用域自动隔离，state.db 位于该 profile 的 sessions/ 子目录），与对话库 state.db 分文件、独立事务作用域。（原默认为扩 `state.db` 以最小化单网关配置，裁定取隔离方案。）

**D3 未登录数据面** — **裁定：强制登录**。
数据面请求须同时携带 Bearer key 与有效会话，无会话返回 `401`。**此为破坏性变更**：存量数据面调用方（如 HermesPaw 未登录态）升级后须完成邮箱登录方可继续用数据面；如需过渡窗口，可临时关闭 `auth.require_session` 开关（本版本默认 true）。未登录时客户端仅展示「关于 / 开源」节。

**D4 邮箱唯一身份** — **裁定：邮箱为唯一登录标识**，`display_name` 可空、登录后可改。

**D5 SMTP 凭据命名空间** — **已按默认建议实施（P1）**：独立 `auth.email.*`（enabled/host/port/security/user/password/from），与 email 平台适配器配置解耦；`auth.email.enabled` 默认 **false（fail-closed）**，未配置时 request-code 返回 502。（P1 回退后该配置项无代码消费方。）

**D6 是否启用邮箱验证码登录** — **裁定：选项 B 不启用（2026-11-17 主控）**。
依据：① 设备 key（QR provisioning）已覆盖服务端数据面认证，key 轮换 = 现成吊销路径；② 单用户场景下邮箱登录的增量价值小（吊销粒度 / 多用户 / 审计）；③ 免 SMTP 运维依赖与免费邮箱授权码风控；④ 防「别人看对话」的正解是手机锁屏 + APP 生物识别锁（客户端侧），非邮箱登录。
处置：P1 网关回退（`api_server_auth.py` 删除 + `api_server.py` 三接线点摘除，`/api/auth/*` → 404；回放包留存 `gateway-patches/p1-auth/`：模块 + selftest + 接线锚点）；P2 客户端代码保留休眠（探针 404 → legacy，登录页不可达，零行为变化）；`account.db` 未部署、无残留。重新启用 = 回放 P1 + 配 `auth.email.*` + 网关重启（届时 D3 强制登录随之生效，需先完成登录 E2E）。

## 6. API 契约（新增 `/api/auth/*` 族）

| 方法 / 路径 | 入参 | 成功 | 说明 |
|---|---|---|---|
| `POST /api/auth/request-code` | `{email}` | `202 {sent:true, ttl_s:300}` | 生成 6 位码，hash 入库，SMTP 发送；限流见 §7 |
| `POST /api/auth/verify` | `{email, code}` | `200 {user:{id,email,display_name}, session_token}` | 校验码（单次消费，purpose 固定 login），签发会话；change_email 码须经 confirm 端点消费 |
| `GET /api/auth/me` | （会话） | `200 {user, session:{expires_at}}` | 当前身份 + 会话到期 |
| `POST /api/auth/logout` | （会话） | `204` | 吊销当前会话 |
| `POST /api/auth/change-email` | `{new_email}` | `202 {sent:true}` | 对 new_email 发码（purpose=change_email） |
| `POST /api/auth/change-email/confirm` | `{new_email, code}` | `200 {user}` | 校验后变更邮箱，吊销该用户其余会话 |

鉴权：`/me`、`/logout`、`/change-email*` 需有效会话（`X-User-Session`）；`request-code`、`verify` 开放但受 §7 限流。数据面（D1-A + D3 强制登录）：`Authorization: Bearer *** + `X-User-Session: <token>` **必填**（无有效会话返回 401；过渡期可关闭 `auth.require_session` 放宽）。

错误体统一 `{error:{message, code}}`；错误码：`invalid_email` / `invalid_json` / `invalid_request` / `invalid_code`（含过期 / 重放 / 尝试超限）/ `invalid_session` / `user_session_required`（D3 数据面闸门，401）/ `rate_limited`（429）/ `smtp_unavailable`（502，不置码状态）/ `email_taken`（409）/ `same_email`。

## 7. 安全口径

- **码**：6 位数字；SHA-256 存储；TTL 5min；**单次消费**（`consumed_at` 置位即失效）；同邮箱同 purpose 仅保留最新码。
- **限流 / 防爆破**：`request-code` 每邮箱 5 次 / 15min（超出 `429`）；`verify` 单码 `attempts` ≥ 5 即作废该码；全局每 IP 30 码 / 15min。
- **会话**：token = `secrets.token_urlsafe(32)`（≥128bit）；仅存 hash；**滑动 TTL 30d**（每次活动刷新 `expires_at`，上限 30d）；`logout` 即时吊销；`change-email` 吊销该用户全部其他会话。
- **传输**：码经邮件（互联网通道）投递；client↔gateway 当前为 LAN 明文（见 README §明文 HTTP），会话 token 在内网明文可接受，**公网部署须上 TLS**（运维口径，非本期代码）。
- **SMTP 凭据**：`auth.email.host/port/security/user/password/from` 走 hermes config / env，**不入仓**（同 `API_SERVER_KEY` 口径）。
- **邮件内容**：纯文本，含 6 位码 + 有效期 + 「码即凭证，请勿转发」提示；**不含可点击链接**（防钓鱼跳转）。

## 8. 邮件通道

- **实施口径（P1）**：`gateway/platforms/api_server_auth.py` 内懒加载复用 `plugins/platforms/email/adapter.py` 的 `_open_smtp` / `_tls_context` / IPv4 强制 helper（剥离平台会话耦合）；插件树不可用时回退 stdlib `smtplib`。未新建独立 outbound 模块（单消费者不抽层）。
- 配置项（hermes config）：`auth.email.enabled`、`auth.email.host/port/security/user/password/from`。
- 失败处理：SMTP 异常 / 未配置（`auth.email.enabled` 默认 false）→ `request-code` 返回 `502 {error:"smtp_unavailable"}`，**不置验证码状态**；客户端提示「验证码发送失败，请稍后重试」。

## 9. 客户端流程（ArkTS）

- **登录页**（未登录态唯一数据面入口：onboarding 完成 / 登出后的首屏）：
  1. 邮箱输入 → 「发送验证码」（点击后 60s 重发倒计时）；
  2. 6 位码输入（数字键盘）→ 「验证登录」；
  3. 成功 → `session_token` 入 `TokenVault`（HUKS），进入登录态。
- **会话恢复**：冷启动读 `TokenVault` 会话 → `GET /api/auth/me` 校验有效 → 登录态；失效 → 回未登录态。
- **数据面**（D1-A + D3）：请求同时携带 `X-User-Session` 与 Bearer key；**未登录禁数据面**（401），展示登录页，仅可见「关于 / 开源」节。
- **登出**：设置→安全→退出登录 → `POST /api/auth/logout` → 清本地会话（**保留档案 / 历史会话**）。
- **流式接收健壮化 + 跨机传输（P4，源自开源同类调研）**：跨机（主控机→236）SSE 长连接不推增量数据（**BUG-005**，见 `docs/test-reports/bug-005-cross-machine-sse-stall.md`）为核心问题；客户端 SSE 缓冲分块解析已在 batch2 落地（`net/SseParser.ets`：UTF-8 边界 + 空行分帧 + `gateSeq` 重放门，`ChatVM.onChunk()` 已走该解析器）。参照 iHermes（`docs/opensource-research/ihermes/`，MIT）与 Conduit（GPL-3.0，**只借思路不复制代码**）——参考源码仅内部留存，不随公开包分发（`tools/opensource-export.sh` 排除项）——按优先级纳入。**状态更新（2026-11-17 审爷 A 轮评审：FAIL→修正清单，已按清单修正）**：①④⑧ 改「已实施 / 剩余差距」口径，②⑥⑧ 引用出处修正（iHermes 无 WebSocket / approval 实现、`listRunEvents` 仅定义未调用），§11 D6 口径统一；**B 轮复审（2026-11-17，report-B）：FAIL→本轮已按清单修正**（4 组行号、§9-5 `pending_controls` 字段与跨机取回口径、⑥ 改「已知未解」、P5 计数 5→6 + `PATCH` 证据分级与 `/approve` 三字段、⑤ 缺口收窄、§11/§12 同步），待 C 轮复审签发（只核修正处文字，不重跑 Part 1 全表）：
  1. **SSE 缓冲分块解析（已实施，转 P2 回归 / 文档同步）**：batch2 已落地——`net/SseParser.ets`（UTF-8 边界 L47、空行分帧 L100、`gateSeq` 重放门 L165——B 轮复核定行号），`ChatVM.onChunk()`（L1134）已走该解析器，原文前提「现 ChatVM 按 chunk 直解析 SSE」不成立。iHermes 引用（`App.tsx:1949-1951` `buffer += chunk` → 空行切块 → `blocks.pop()`）已核实属实、与已实现语义一致，保留作参照核对。剩余：确认无残留直解析路径 + 回归（chunk 边界 / 半截事件 / `gateSeq` 重放负例）。
  2. **跨机传输降级 / WebSocket（P1 长期治本；WS 为自有方案）**：根治 BUG-005。**WS 鉴权口径（D6 补充）**：D6 下唯一凭证为 device-key（Bearer）→ WS 握手走 query token 或首帧鉴权（浏览器侧无自定义 header 能力），不得引入会话 token 依赖（不预设邮箱登录）。过渡方案「SSE 主通道 N 秒无 chunk → 自动降级备用传输」兜底。**状态更新（2026-11-17）：方案 B（getRun 轮询兜底）已实施**（`3927969`，bug-005 报告，**模拟器已验证、真机跨机待验**）——客户端不再卡死（≤~20s 出结果，但静默期无增量流式）；本项 **P1（长期治本）**，保留 P1 的真实理由 = BUG-005 根因（服务端跨机 SSE 推送链路，待 236 网关排查）未查清。**引用更正**：iHermes 无 WebSocket 实现（已核实 0 次），WS 方向为自有方案，无开源参照。
  3. **P1 传输双通道 + 用户可取消**（参考 iHermes `client.ts` `request()`）：主通道 + 备用通道自适应；`AbortController` 用户可取消——内部超时与外部用户 abort 信号合并到同一 controller（外部已 aborted → 直接 abort；否则订阅 abort 事件、finally `removeEventListener`，`client.ts:88-137`，已核实属实；`CHAT_TIMEOUT_MS=180_000` 实际在 `App.tsx:75`，且该合并模式只覆盖非流式 `request()`，流式在 `App.tsx:1695-1712`，本条实现应对照后者）。统一超时已具备（`ApiClient.ets` `SSE_IDLE_TIMEOUT_MS` 空闲看门狗 L29/L213 + http task `destroy()` L186/296，B 轮复核定行号），本条定位为「用户可取消 + 通道切换」。ArkTS 映射为 `setTimeout` + http task `destroy()`。
  4. **工具步骤状态机（已实施，转字段口径统一 + 时长来源核对）**：batch2 已落地——`model/ToolStep.ets`（`toolCallId`/`tool`/`durationSec`/`state`，`state` 三值：`running`/`ok`/`error`），UI 渲染「执行中 / 完成 / 失败 + 耗时」。iHermes 引用（`App.tsx:43` 三态、`:50-56` 字段、`:977-1010` push/complete）已核实属实，保留作参照；剩余差距：不另立 iHermes 字段体系（重复建设），统一以现有 `ToolStep.ets` 为口径 + 核对 `durationSec` 计算来源。
  5. **工具审批闸门（已实施，转回归验证）**：敏感工具（高危命令 / 写盘删除 / 外呼）调用前网关挂起 run（status `waiting_for_approval`）→ 同一 SSE 流推 `approval.request` 事件（payload 含脱敏 command/description + choices 选项）→ 客户端会话内渲染审批卡片，用户确认/拒绝 → 回调 `POST /v1/runs/{run_id}/approval` 提交 choice → run 恢复/终止。**无需网关改动**。**客户端已实施**：`ChatVM` `approval.request` → 审批卡片（4 choices + 60s 展示倒计时，`APPROVAL_TIMEOUT_SEC=60`）→ `approval.settled` 收口；S3-b 挂起期抑制 getRun / 重订阅。跨机场景（B 轮复审更正）：getRun 状态快照在等待审批期间含 `pending_controls` 字段（字段名以 `Run.ets:67` 为准），但**客户端当前无 `pending_controls` 消费点**（`ChatVM` 仅解析 SSE 流的 `approval.request` 载荷：`parseApprovalControl` L1179，L1177 仅注释）——故「方案 B 轮询同样可取回待审批」**不成立、当前不支持**；要支持需客户端补一处 `recoverTick` 分支（轮询快照含 `pending_controls` 时回填审批卡片，约 1 处），列为 P4 遗留项。网关侧状态写入路径 `gateway/platforms/api_server_runs.py::_set_run_status`（L311-330）/ `_handle_get_run`（L1249）236 环境已核实存在（状态可取回，缺的是客户端回填）。**引用更正**：iHermes 无 approval 实现（已核实 0 次），本特性为自有网关原生能力 + 客户端实施，不挂 iHermes 名下。与 D3 强制登录正交（工具层 vs 身份层，互不影响）。
  6. **P1 错误可见 + 用户主动重试**（参考 iHermes App.tsx 错误气泡 + `handleRetryLast`，引用已核实：`App.tsx:893` / `:177-186` `canRetry` / `:827-830`）：流异常（超时 / 网络分区 / 轮询终态取回失败）后在会话内追加可见错误气泡（不静默失败、不替用户自动重发——自动恢复已由 recoverTick 负责）；错误气泡内提供一键「重试上一条」（重发最后一条用户消息，`canRetry` 置位才可用）。缺口收窄（B 轮复审）：现已有连接错误条重试（`ChatPage.ets:759`，重跑连接测试）+ 气泡长按重发（`:1154`，S2-b）；真正缺的仅是**错误气泡内一键「重试上一条」**，不与既有重发功能重复实现。跨机传输不稳定时最低成本的 UX 兜底。
  7. **P2 轮询模式工具步骤时间线补齐（端点 code ref 已给；iHermes 仅定义未调用）**：方案 B 轮询 finalize 只回填终文本 `output`，静默期已执行的工具步骤事件不回填（UI 工具时间线缺段）。终态取回后再拉全量事件序列补齐工具步骤时间线。端点 code ref：`gateway/platforms/api_server_runs.py::_handle_run_events`（`GET /v1/runs/{id}/events`——236 环境已核实：**仅 SSE 流式输出**，支持 `Last-Event-ID` / `last_seq` 重放，无非流式 JSON 事件列表模式），自有客户端在用点 `RunsApi.ets:96`。**已知未解（B 轮复审）**：轮询模式下客户端刻意不重开流（L1747/1860，注释「死流重放只会再挂」），`Last-Event-ID` 重放仍走同一条跨机不稳定的 SSE 通道，补不了静默期缺段；轮询模式工具时间线补齐需**网关侧提供非流式事件列表端点**（网关侧前置项，不属当前 P4 范围，待网关提供后排期）。**引用更正**：iHermes `listRunEvents` 仅 `client.ts:68-70` 有定义、App.tsx 调用 0 次——「借鉴其做法」不成立，本条为基于网关端点能力的自有设计。
  8. **P2 轻量 Markdown 渲染**（参考 iHermes `simple_markdown.tsx` 的刻意窄子集，已核实准确：`:3-12` 仅 heading/image/table/link/bold 五类，`parseBlocks:134-199` 无围栏、无列表分支）：标题 / 表格 / 图片 / 粗体 / 链接；**刻意不做代码围栏与列表**（限定范围，避免引入重 Markdown 库）；纯函数无状态解析（每次增量更新全量重解析，天然兼容流式半截内容——未闭合表格行 / 粗体按原文渲染不报错）。现 ChatVM 纯文本渲染，agent 高频输出的表格 / 标题目前显示为原文。**布局约束**：宽表进横向滚动容器（iHermes 用横向 ScrollView + 单元格内联解析），ArkTS 侧对齐防宽表溢出。
  > 维持现状（不借鉴）：密钥存储已用 HUKS AES-256-GCM（领先 iHermes 明文 SecureStore）、扫码配置为独有优势；Conduit 14 语种不照搬，i18n 按用户群实际扩展（P3）。
- **斜杠命令映射（P5，客户端拦截 → API，网关零改动）**：Hermes 网关原生有会话命令集（`/new` `/resume` `/sessions` `/branch` `/title` `/save` `/undo` `/retry` `/topic` `/compress`，`gateway/slash_commands_session.py`，2026-11-17 核实），但仅对走消息管道的 surface（CLI、企微 / Telegram）生效；APP 的 REST API 面（`POST /api/sessions/{id}/chat` → `_run_agent`）不经命令分发——输入 `/xxx` 会被当普通消息发给模型，APP 退化为纯聊天。对策：APP 输入框识别 `/` 开头命令并拦截，转成等价 API 调用——**映射目标是已实证的 API 端点，不是原生命令名**：
  1. **P1 核心映射表**（纯客户端，`net/SlashCommands.ets` 单文件单一事实源，一命令一条目 `{pattern, 说明, executor}`，ChatVM 发送路径拦截）：`/new` → `POST /api/sessions`（`busy` 态下 newSession 静默 return（L530）：斜杠命令提示「请等当前任务完成后再切换」，不发重复请求；标题唯一性后缀（L539）由 API 自动处理）；`/resume [序号|关键词]` → 无参拉 `GET /api/sessions` 列历史会话，带参切目标会话（`GET /api/sessions/{id}/messages` 重拉 + 以该 `session_id` 继续对话，即现有 takeover 路径；目标会话 `busy` 态时 takeover 路径静默 return（L1590）：斜杠命令须显式提示「目标会话忙碌，无法切换」，避免用户以为切了实际没切）；`/title [名称]` → 无参显当前 title，带参 `PATCH /api/sessions/{id}` `{title}`；`/stop` → `POST /v1/runs/{run_id}/stop`（无在飞 run 时提示系统气泡「当前无运行任务」，不发请求；是否复用现有 stop 二次确认弹窗 `onStopRequested`（L316）待实现时定）；`/approve [choice]` → `POST /v1/runs/{run_id}/approval`（**三字段缺一不可，缺任一实证 400**（`RunsApi.ets:72-86`）：`request_id` + `execution_generation` 取自最近 `approval.request` SSE 事件或 `pending_controls` 快照，+ `choice`（choices 同 P4 工具审批闸门）；无待审批时直接提示，不发请求）。映射涉及的 6 个端点逐一核实（2026-11-17，B 轮复审）：`POST /api/sessions` / `GET /api/sessions` / `GET /api/sessions/{id}/messages` / `POST /v1/runs/{id}/stop` / `POST /v1/runs/{id}/approval` 五个有**真实请求实证**（L2 自测通过）；`PATCH /api/sessions/{id}` 为**网关代码实证存在**（路由 + handler `api_server.py` L2654），真实请求待 T2 补齐。
  2. **未映射命令与未知前缀**：原生 10 命令中未映射的（`/branch` `/save` `/undo` `/retry` `/topic` `/compress` `/sessions`）在 APP 内显式提示「当前不支持」（系统气泡，不发模型）；不在已知集合的 `/xxx` 按普通消息原样发送（不挡以 `/` 开头的合法内容，含以 `/` 开头且带空格的多词文本——按消息发送，不按命令拦截）。命令执行结果以系统气泡呈现，不占用户消息气泡。
  3. **Hermes 原生命令变更时的维护方式**（P5 核心约束，避免映射表随网关升级腐烂）：① **解耦**——映射目标为稳定 API 端点而非原生命令名：原生命令集改名 / 增删不自动波及 APP 映射表；新增原生命令只有当 APP 需要将其暴露给客户端时才加一条（前提：有对应 API 端点，否则标 CLI-only）；② **漂移检测**——自测对映射表每条目做端点探测（期望结构化 4xx 而非 404），网关升级移除 / 改名端点时自测变红即知映射表需修；③ **单一事实源**——映射表只存在于 `SlashCommands.ets`，设计文档只引用；新增命令 = 加一条目 + 一条自测，无第二份要同步。
  4. **P2 命令提示 UI**（后续排期）：输入 `/` 时弹候选列表（命令 + 一句话说明），降低记命令成本。

## 10. 设置四节（UI 规格）

设置页在现有「档案列表」基础上增四节（分区，非独立 Tab，呼应 A3「合并 更多→设置」的单一设置页收口）：

| 节 | 内容 | 可见性 |
|---|---|---|
| 用户信息 | 邮箱、显示名（可空可改）、账号创建时间、最近登录 | 登录后 |
| 安全信息 | 当前会话（设备 / 到期）、**退出登录**、**更换邮箱**；网关 key 状态只读 | 登录后 |
| 关于 | App 版本 / 构建号、hermes-agent 版本、当前网关地址、API 契约版本 | 恒可见 |
| 开源信息 | LICENSE（MIT）全文 / 链接、第三方组件清单、开源致谢 | 恒可见 |

D3 强制登录下：未登录态仅展示「关于 / 开源」节；「用户信息 / 安全信息」登录后出现（登录入口 = 未登录首屏，见 §9）。
**选项 B 范围收敛（D6 裁定 2026-11-17）**：邮箱登录不启用 → 应用恒 legacy 态——实施范围 = 「关于 + 开源信息」（恒可见节）+「安全信息」内网关 key 状态只读行；「用户信息」节、当前会话 / 退出登录 / 更换邮箱等登录依赖行不实施（上表「可见性」列保留全量口径供重新启用路径参照）；2026-11-18 已按此范围实施（`03e1200`，见 §11 P3 行）。
- 文案全走 i18n（`app.string.*`，三 locale：base / zh_CN / en_US）。
- 配色走 `color.json` + accent 模块（与 A3 一致），不硬编码 hex。

## 11. 分阶段实施建议

| 阶段 | 交付 | 自测 |
|---|---|---|
| **P1 网关** ⏪ 已回退（2026-11-17 实施 selftest 26/26 → 同日依 D6 选项 B 回退：模块删除 + 3 接线点摘除，`/api/auth/*` → 404，回放包 `gateway-patches/p1-auth/`） | `/api/auth/*` + 账号/码/会话存储（独立 `account.db`）+ SMTP 出站 + 限流 + 数据面强制登录校验（D3）— 网关侧：`gateway/platforms/api_server_auth.py`（新增）+ `api_server.py` 三处接线（import / 路由 / 中间件） | `tools/auth-selftest.py` **26/26 通过**（契约 + 限流负例 + 无会话 401 负例 + 换邮箱吊销 + SMTP 失败 + D3 开关） |
| **P2 客户端登录** ✅ 已实施 → 休眠（2026-11-17，`5c064c4`+`2871e33`；依 D6 P1 回退 → 探针 404 → legacy，登录页不可达，零行为变化） | 登录页（邮箱+6 位码+60s 倒计时）+ 会话 TokenVault 持久化（`sess:` 命名空间信封，TokenVault 零改动）+ `authMode` 三态（legacy/loggedOut/loggedIn，`GET /api/auth/me` 单探针 fire-and-forget 决议）+ 冷启动会话恢复 + 数据面闸门（ChatPage Stack 覆盖层 + 3 处 catch 对 `user_session_required` 反应式降级）+ `X-User-Session` 双层头（D1=A，ApiClient 条件挂载）+ i18n 11 键×3 语言。新增 `net/AuthApi.ets` / `store/AuthSession.ets` / `viewmodel/LoginVM.ets` / `pages/LoginPage.ets`，改动 `ApiClient` / `ChatVM` / `ChatPage` / `main_pages.json` | 236 侧：L2 五件套 **5/5 绿**（2026-11-17）；待主控真机：T1 构建 + 登录 E2E（发码需 `auth.email.enabled=*** 网关重启后生效）+ 未登录闸门负例 + 冷启动恢复回归 |
| **P3 设置（精简）** ✅ 已实施（2026-11-18，`03e1200`） | 关于（App 版本/构建号（bundleManager）+ API 契约版本（`API_CONTRACT_VERSION='v1'`，ApiClient 导出）+ 当前网关地址 + hermes-agent 版本（**无鉴权 /health 探针**拉取，失败降级「未提供」，不改网关））+ 开源信息（MIT 全文嵌入常量、展开全文可复制 + 开源致谢 + 第三方组件=无）+ 安全信息（网关 Key 状态只读：NONE/OPEN/CONFIGURED + 诊断验证标记；batch2-r7 免鉴权为合法态）；登录依赖行不做（见 §10 选项 B 收敛）。i18n 24 键×3 locale；顺带收口留白-01（bootError 硬编码 ×6 → `getStringSync` 占位符 i18n）与留白-02（诊断基础句硬编码 → 声明式 `$r()`，删 `appLangShort`） | 236 侧：L2 五件套 **5/5 绿**（2026-11-18）；待主控真机：T1 构建 + 三区可见性/文案核对 + 许可证展开/复制 + 激活切换刷新 + 版本降级「未提供」负例 + 诊断句热切换语言验证 |
| **P4 流式健壮化 + 跨机传输**（源自开源同类调研，规格见 §9 末段；**2026-11-17 审爷 A 轮 FAIL→已按修正清单改口径**） | ①SSE 缓冲分块（**已实施** batch2 `SseParser.ets`，转 P2 回归 / 文档同步）②跨机传输降级 / WebSocket（需网关 WS 端点，**自有方案**；**方案 B getRun 轮询兜底已实施 `3927969`，模拟器已验证、真机跨机待验，本项 P1 长期治本**）③传输双通道 + 用户可取消（统一超时已具备）④工具步骤状态机（**已实施** `model/ToolStep.ets`，转字段口径统一 + 时长核对）⑤错误可见 + 用户主动重试（纯客户端，缺口真实）⑥轮询模式工具步骤时间线补齐（端点 code ref：`api_server_runs._handle_run_events`——**仅 SSE 输出，已知未解**，补段需网关提供非流式事件列表；iHermes 仅定义未调用）⑦轻量 Markdown 渲染（纯客户端，补宽表横向滚动约束）⑧工具审批闸门（**已实施** `ChatVM` 审批卡片 60s 倒计时，转回归验证） | 单测 + 真机跨机（⑤纯客户端先行；②③需网关配合；①④⑧为已实施项回归；方案 B 真机跨机验证通过前 BUG-005 不关闭） |
| **P5 斜杠命令映射**（客户端拦截 → API，网关零改动，规格见 §9） | ①核心映射表 `/new` `/resume` `/title` `/stop` `/approve`（纯客户端，6 端点：5 个真实请求实证 + `PATCH /api/sessions/{id}` 网关代码实证存在、真实请求待 T2）②未映射原生命令显式「不支持」③维护机制：映射目标 = API 端点（与原生命令名解耦）+ 端点探测自测 + 单一事实源④命令提示 UI（后续排期） | 映射表 6 条目单测（调对端点、模型零调用）+ 端点探测自测负例（端点移除 → 红）+ `/approve` 三字段负例 + `/stop` 空闲 / `/resume` 忙态负例 |

每阶段独立可交付：P1 落地即可被 API 自测验证，不阻塞 P2 / P3 的设计推进。P4 与 P1–P3 正交（流式传输 / 工具交互层，不动现有 device-key 鉴权——D6 单凭证口径），可并行推进；P5 同为纯客户端（映射端点已实证，网关零改动），可在 P4 先行项落地后排期；具体规格见 §9。

## 12. 测试目标（供后续 `test-target-s4.md` 展开）

- **T2 契约**：`request-code` / `verify` / `me` / `logout` / `change-email*` + 限流 / 防爆破负例（429 / 码作废）。
- **T3 功能**：发码 → 收码 → 验证 → 登录态 → 数据面带身份 → 登出 → 换邮箱全链。
- **T4 负例**：错码 / 过期码 / 重放已消费码 / 限流触发 / 未登录访问需会话接口 → 401 / 数据面无有效会话 → 401（D3）。
- **L3 真机**：SMTP 真实发码 E2E（含 60s 重发倒计时、6 位码输入、冷启动会话恢复）。
- **P4 流式/传输（规格见 §9 末段）**：SseParser 已实施回归（chunk 边界 / 半截事件 / 多字段增量归一化 / `gateSeq` 重放负例——①已实施项）；方案 B 真机跨机验证（发「下午好」≤~20s 出终态结果、不再卡 186s）；BUG-005 根因回归（服务端跨机 SSE 推送链路，236 网关排查后 SSE 增量流跨机恢复）；传输降级 / 用户可取消 / 超时处理；工具步骤状态机渲染回归（④已实施 `ToolStep.ets`）；工具审批全流程回归（⑧已实施：`approval.request` → 卡片确认/拒绝 → run 恢复/终止；跨机「取回待审批」当前不支持——客户端无 `pending_controls` 回填，见 §9-5，测试项暂缓，待 `recoverTick` 分支落地后补入）；「重试上一条」/ 错误气泡负例（⑤缺口实施：流中断网后重试）；⑥轮询时间线补齐（**已知未解**：待网关非流式事件列表；`Last-Event-ID` 重放仅对 SSE 流内有效，不覆盖轮询模式）；⑦宽表横向滚动。
- **P5 斜杠命令**：映射表 6 条目单测（各调对应端点、模型零调用）；未映射原生命令（如 `/branch`）→「不支持」系统气泡、模型零调用；未知 `/xxx`（含以 `/` 开头且带空格的多词文本）按普通消息发送（模型收到原文）；漂移自测负例（探测端点不存在 → 自测红）；`/approve` 字段完整性负例（缺 `request_id`/`execution_generation` → 400）；`/stop` 空闲态负例（无在飞 run →「当前无运行任务」提示、不发请求）；`/resume` 忙态负例（目标会话 `busy` → 显式「无法切换」提示）。
