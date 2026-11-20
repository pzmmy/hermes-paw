# S1 测试目标声明（7 层测试框架用）

> 定位：本工程面向 7 层测试框架的**机器可验证测试目标锚点**。
> 背景：2026-10-31 七层测试 T0 前置核查 FAIL——任务卡对象（commit 4acba48 + Home/TodoList/MineList）
> 在本仓不存在（他工程孤儿任务，错路由）。根因 = 任务卡对象无仓内锚点。
> **凡指向本工程的测试任务卡，一律以本文件声明的对象为准；T0 必须先跑下列校验命令，FAIL 即按规范中止。**

## T0 前置（机器可校验，FAIL 即中止）

| 核查项 | 期望值 | 校验命令 |
|---|---|---|
| 项目标签 | `hermes-paw` | 宿主 git 目录下仅 hermes-paw 仓；**不存在名为 hermes-sre 的仓**（引擎配置标签若为 hermes-sre 即错标） |
| remote | `<host>:/path/hermes-paw.git` | 主控 remote 必须指向此 bare repo |
| 目标 commit | `ef75bca` | `git cat-file -e ef75bca` |
| HEAD | master 包含 ef75bca 祖先（其后仅允许 docs 提交） | `git merge-base --is-ancestor ef75bca origin/master` → rc 0 |
| 页面集 | 20 个 .ets | `find entry/src/main/ets -name '*.ets' \| wc -l` → 20 |
| 环境前置（T4/T5 用） | 宿主 Windows 防火墙规则 "HermesPaw 8377" 的 Profile 覆盖真机所在网段网卡（手机/宿主同 31.x 段，网卡 profile = Private） | 宿主管理员 PowerShell：`Get-NetFirewallRule -DisplayName "HermesPaw 8377" \| Select-Object Profile` → 须含 PRIVATE 或 ANY；仅 Public 则 T4/T5 必然网络层阻塞（D-1 先例 2026-10-31：Tcp False / Ping True，修 = `Set-NetFirewallRule -DisplayName "HermesPaw 8377" -Profile Any`） |

页面集清单（4 页面 + 16 支撑）：
pages/{Index,ChatPage,ScanPage,SettingsPage}.ets；entryability/EntryAbility.ets；
model/{ChatMessage,LocalSession,Profile,Run,SetupUri,ToolStep}.ets；
net/{ApiClient,RunsApi,SessionsApi,SseParser}.ets；store/{DbHelper,TokenVault}.ets；
viewmodel/{ChatVM,ScanVM,SettingsVM}.ets。

**负锚点**：本工程无「二级 Tab / 已审批 / 待审批 / todo 角标」页面族（无 Home/TodoList/MineList）。
任务卡点名此类文件时，T0 应判对象错路由并中止。

## T2 契约层

- 基准脚本：`tools/api-selftest.py`（26 用例，236 侧全绿；六大类 R 只读 / W 写 / A 审批 / S 会话 / P profile / X 负例；
  `--only R,W,A,S,P,X` 选类；退出码 0=全绿、1=存在 FAIL；证据 `evidence/selftest-*.jsonl` 本地保留不入库）。
- S1 API 面（代码 verbatim，M0a 证据已核）：
  - run 族：`POST /v1/runs`（202 {run_id}）；`GET /v1/runs/{id}`（真相源：status=waiting_for_approval +
    pending_controls[{kind, prompt_id, command, description, choices:[once,deny,session,always]}]）；
    `POST /v1/runs/{id}/stop`；`POST /v1/runs/{id}/steer`（200 {accepted:true}，body {input}）；
    `POST /v1/runs/{id}/approval`（body {request_id, execution_generation, choice}，缺一 400，A-3 实证）；
    `GET /v1/runs/{id}/events`（SSE）。
  - session 族：`GET /api/sessions`（200 {data:[...]}，R-05）；`POST /api/sessions`（201 {session:{id}}，W-01）；
    `GET /api/sessions/{id}/messages`（全量重拉，S-01）。
  - SSE 契约：外层 `event:` 行实践中为空，业务事件名在 data JSON 的 `event` 字段（fallback `type`）；
    终态事件 = run.completed / run.failed / run.cancelled / run.interrupted。
  - 认证：数据面硬需 Bearer API_SERVER_KEY（health 端点开放）。

## T3 功能层（主控 DevEco 真机轮）

- S1 验收 a-d：
  a) 审批卡四动作（once/deny/session/always）；
  b) 60s 超时 D2：本地倒计时仅展示，服务端超时自动拒绝为真相源（App 轮询 GET /v1/runs/{id} 每 5s）；
  c) 后台 5 分钟恢复（seq 门去重 + 快照回填）；
  d) /steer 运行中插话。
- QR 配置（S1-a）：管理码 = default profile + 主 key（全功能）/ 用户码 = guest + 独立 key（受限，disabled_toolsets）。

## T4 负例

- 审批体缺字段 → 400（A-3 实证）；
- 数据面无 token → 401（health 200 正常）；
- SSE 乱序/重复 seq → 不重渲染（seq 门）；
- 审批窗口过期（服务端 60s）→ 轮询反映状态变化（自动拒绝）。

## T5 回归

- `--prev` = 本工程上一轮 JSON。若 20261027 轮目标即本工程则用 hermes-paw_测试报告_20261027.json；
  若该轮目标为他工程（4acba48 事件），本轮为基线，不参与回归。

## T6 交付门

- 泄漏扫描（token / key / 内网地址）、无本机绝对路径、无占位符。

## 版本链（git log --oneline 可验）

e6fef9c (M0a selftest) → M1 段 (09dd728..4b11068) → 218efcc (M2-batch1) → 0f858ec (S0 QR)
→ 6426864 (S1-a) → 47e20dc (S1-b1) → 449d252 (S1-b2) → 0d4e8c7 (首编修复) → **ef75bca (二编修复，当前)**
