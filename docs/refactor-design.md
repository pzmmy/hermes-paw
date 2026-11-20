# HermesPaw 重构设计（v1.6 送审稿）

> 状态：**设计稿，未编码**。本文只回答"改哪里、为什么改、改到什么程度算完"，不含实现代码。
> 送审通道：170 审爷（签发前不动代码）。
>
> 修订记录：
> - v1.6（2026-11-18）：**按 R3 判定补掉 4 条"半改"**——① §0 结论第 2 条删掉 2.5s 内容口径，改为"1.5s 可见进展 + 快照 ≤5s P50"；② §R1 表 #2 改为"握手 3s / 判死 15s 无字节 / 绝对 30min"三者分离，禁止混用；③ §R1 表 #4 明确"心跳不续命"只适用 typed-idle，本设计用字节级判死、心跳**计入**有效字节；④ §R1 表 #3 删除重连预算副本，只留指针；⑤ §R3 终态集合补 `canceled` 并与 `Run.ets:38` 对齐；⑥ §R11 深色 accent 为浅底，`text_on_accent` 深色改深墨 `#0F1216`（原缺，白字必 <4.5）。
> - v1.5（2026-11-18）：**按审爷 R2 的"不通过"6 条必改项逐条闭环**——① §R0 新增单次 `getRun` 硬上限 3s + 在飞跳过 + ticker 自检，S1 前置改为"跨机 getRun 实测通过"；② SSE 可用性改为"拿到响应 + 至少 1 帧（含注释/心跳）"，不再与首字绑定，另设 15s 无字节判死；③ 验收拆成"UI 可见 ≤1.5s"与"首个非空快照 ≤5s/≤10s"两条，删除 2.5s 内容口径；④ 重连预算归一到 §R0-2，§R3 只引用；⑤ 清除 90s 残留（§1.4/§R0 问题段）、R2 终态补 `canceled`；⑥ §R10 的 #7/#8 并入 §R7 单一定义、#9 降级 P1 并先做能力探针、#10 标数据源待核，GPL 守卫口径限定为"降低风险"。
> - v1.4（2026-11-18）：新增 **§R12 性能 / §R13 安全 / §R14 健壮性**——全部先实测再落方案：`LazyForEach` 0 处（10 处 `ForEach` 全量渲染）、`Markdown.ets:10` 自陈每次渲染全文重解析、`onUnhandledException` 0 命中（无全局异常钩子）、`RunsApi.ets:43` 自陈"`readTimeout` 对半开连接不生效"、`module.json5` 无 cleartext 声明、`TokenVault` 的 HUKS/TEE 已达标（明确不动）；配套新增 S4b/S10/S11 与 4 条开源门槛。
> - v1.3（2026-11-18）：新增 §R11 **UI 视觉体系重构**——用实测数据取代审美判断：12 档字号、37 处裸 hex、23 语义槽、无 `dark/` 目录；并用 WCAG 公式算出**当前 5 个语义色不达 AA**（`text_hint` 2.57、`warning` 2.95、`accent[0]` 3.68、`danger` 4.05、`text_secondary` 4.41），逐条给出替换值与新对比度；配套 `ui-audit.py` 可机判门槛，实施顺序新增 S9。
> - v1.2（2026-11-18）：吸收审爷 R1 结论——修正 idle 现值为 30s（原写 90s 为笔误）；状态机补 `degraded_polling` 出边并把审批改为正交子状态、终态枚举对齐 `Run.ets:38`；绝对上限触发改为"可重开取回"不判 failed；权威对账先剔除 thinking 段；`resolve-unknown` 端点已核实存在（`api_server.py:70`）；新增 §R10 **产品与工程层借鉴** 13 条 + 反面清单 4 条 + GPL 守卫；§6 补 `getRun` 跨机慢/`setTimeout` 不可靠/长时任务配额三条风险；§7 补 GPL 与截图机判门槛。
> - v1.1（2026-11-18）：按用户实测痛点反转传输主从关系——新增 §R0 双通道并行；§R3 改为"放弃条件由 status 决定"；轮询起步 2s；新增 SSE 借鉴清单（10 条 + 1 条反面）。
> - v1.0（2026-11-18）：初稿。

---

## 0. 结论先行

1. **边界：只改 App，不改 Hermes gateway。** 任何需要动 `~/.hermes/hermes-agent/**` 的方案一律不做——gateway 是多用户共用的（236 上跑着企微 7×24），改它会污染别人的使用感受。本文全部条目均在 `entry/src/main/ets/**` 内闭环。
2. **传输主从关系反转：getRun 轮询是基线，SSE 只是增强。** 实测痛点（2026-11-18 用户）：鸿蒙侧 SSE 不稳、响应慢，内核对 chunked 流式的支持不成熟。因此本设计**不把"修好 SSE"当成前置条件**——SSE 一帧都收不到时，App 仍须在 **1.5s 内出现可见进展**（"已提交 / 等待模型"），并按快照增量推进（首个非空快照 ≤5s P50；内容口径见 §R0-7）。这一条推翻了 v1.0 初稿把 SSE 当主路径的假设。
3. **BUG-005 的根因判定要推翻。** 实测证明 gateway 对跨机客户端的 SSE 完全正常（见 §1.2），"服务端缓冲"不成立。但**这不等于"客户端能修好"**——鸿蒙流式实现本身的成熟度是独立约束（§1.4）。
4. **重构主体是三件事**：① `ChatVM` 2376 行里的隐式状态机显式化；② 传输策略改成"轮询基线 + SSE 增强"的双通道；③ 借 Conduit 的恢复语义与 iHermes 的字段归一，补四个协议级缺口。
5. **不做的**：WebSocket 数据面、多租户、远程/跨网、gateway 补丁、CRDT/离线写、把"逐字流式"当成产品承诺。

---

## 1. 现状（实测值 + 来源）

### 1.1 代码规模（`git show d951a51`，2026-11-18）

| 模块 | 行数 | 说明 |
|---|---:|---|
| `viewmodel/ChatVM.ets` | 2376 | 会话编排 + 流式接收 + 审批 + 恢复 + 重试，五件事混在一个类 |
| `pages/ChatPage.ets` | 1706 | 列表 / 气泡 / 输入区 / 审批卡 / 工具流水 全在一个 build 里 |
| `pages/SettingsPage.ets` | 745 | 设置页 |
| `viewmodel/SettingsVM.ets` | 620 | 设置 VM |
| `store/DbHelper.ets` | 607 | 关系型存储 |
| `store/TokenVault.ets` | 443 | HUKS 密钥保险箱 |
| `pages/ScanPage.ets` + `viewmodel/ScanVM.ets` | 373 + 291 | 扫码接入 |
| `net/ApiClient.ets` | 340 | HTTP + SSE 流 |
| `net/SseParser.ets` | 276 | 字节流分帧 |
| 其余（net 8 / model 8 / 各页） | ≈3600 | — |
| 合计 | ≈11900 | 4 个 viewmodel 3519 行，7 个 page 3474 行 |

`components/` 为空目录、`i18n/` 尚未成目录——UI 组件与文案没有独立层。

### 1.2 BUG-005 根因改判（决定性实测）

原文判定（`docs/test-reports/bug-005-cross-machine-sse-stall.md`）：gateway 对非本机客户端的 SSE 写入被缓冲。

**实测反证（2026-11-18，WSL → 236，跨机）**：

| 观测 | 值 |
|---|---|
| `POST /v1/runs` 建 run | 成功，返回 run_id |
| `GET /v1/runs/{id}/events` 首字节到达 | **t+0.07s** |
| 35 秒内累计字节 | **3039 B**，`message.delta` 逐帧连续，`seq` 单调 |
| 帧格式 | `: open` 注释帧 + `id:`/`data:` 完整 |

结论：**跨机 SSE 服务端侧无缓冲问题**。原报告的对照实验缺了"跨机 curl"这一格（只对比了 loopback curl 与跨机 App），因此结论把客户端问题误记到服务端。

改判后的处置：
- 恢复/轮询链路保留，但**降级为兜底**，不再承担"跨机唯一可用路径"的定位；
- 客户端流式层是主攻方向（§3.1）；
- 本文所有方案不依赖 gateway 任何改动。

### 1.3 现有恢复策略参数（`ChatVM.ets:63-110`，逐条原文）

| 常数 | 值 | 现状问题 |
|---|---|---|
| `APPROVAL_TIMEOUT_SEC` | 60 | 硬编码，与服务端 `approvals.timeout` 解耦（236=60s、WSL=120s、默认=300s） |
| `APPROVAL_POLL_MS` | 5000 | 固定节奏，不随剩余时间自适应 |
| `RECOVER_BACKOFF_BASE/MAX` | 1s / 30s | 指数 1-2-4-8-16-30 |
| `RECOVER_TIMEOUT_MS` | 150s | 纯墙钟；长任务（5-6 分钟）会提前放弃 |
| `RECOVER_POLL_TIMEOUT_MS` | 600s | 为上述缺口打的补丁：poll 模式放宽到 10 分钟 |
| `RECOVER_GETRUN_POLL_TIMEOUT_MS` | 10s | JS 层竞速 + SDK 15s 双保险，注释自陈"ArkTS async 下 setTimeout 不可靠" |
| `RECOVER_POLL_INTERVAL` | 5s（可配 1–60s） | 用户可调，但语义是"多久查一次"，与"还算不算在跑"无关 |
| `RECOVER_POLL_FAST_WINDOW/INTERVAL` | 30s / 2s | 前 30 秒快轮询，30 秒后切退避 |

**这套参数是三轮补丁叠出来的**（代码注释里留着"方案 A 未解决 / 方案 B 引入新 bug / 方案 C 修死锁"的痕迹）。问题不在数值，在于**没有区分"还在跑"与"已经不动了"**：一个纯时间轴无法表达这件事，所以每遇到一种新故障就加一个常数。

> 事实校正（审爷 R1 指出，已核 `ApiClient.ets:37`）：现有 idle 看门狗是 **30s**（`SSE_IDLE_TIMEOUT_MS = 30000`），不是 90s；`SSE_READ_TIMEOUT_MS` 同为 30s。本文早期版本写作 90s 系笔误，凡涉及"现有 idle 值"一律以 30s 为准。

### 1.4 鸿蒙流式实现的成熟度（本次设计的外部约束）

用户实测结论：**SSE 不稳、响应慢，鸿蒙内核对 chunked 流式响应的支持不成熟**。

这条约束的工程含义（决定了 §R0）：

| 若把 SSE 当主路径 | 后果 |
|---|---|
| 等首帧 | 不可控：可能 0.07s（WSL 侧实测），也可能整轮 0 字节 |
| 收不到帧时的判定 | 只能靠 idle 超时（**现设 30s**，见 §1.3），用户实际体验到的是"转圈几十秒然后报错" |
| 恢复链 | SSE 失败 → 退避 → 轮询，**第一份可用数据要经过两级失败才出现**，这就是"响应慢"的主要来源 |

因此本设计不再把"让 SSE 稳定"当作目标函数，而是把它降级为**可选加速器**：SSE 通就是逐字，不通就是快照，两条路的首屏时间都要达标。

---

## 2. 参考实现的可用结论（代码级，已核）

两份源码快照**不随仓库分发**（已于 2026-11-19 移出并本地归档；对外声明见 `docs/third-party-references.md`）。

### 2.1 Conduit（Flutter，GPL-3.0）——只借语义，不搬代码

| 机制 | 常数/判据（已逐条核对源文件行号） | 我们的差距 |
|---|---|---|
| 流守卫 | idle 5 分钟（可恢复）、绝对 30 分钟（fail-closed） | 我们只有 idle 概念，没有"绝对上限 vs idle"的区分 |
| 恢复轮询 | **快 120×1s + 慢 300×5s，慢预算只为 `lastStatusActive` 续命** | 我们是"墙钟 150s/600s + 退避"，两个 run 分不开 |
| 重连退出条件 | 无进展 3 次 + 全程 50 次 + HTTP 404 放弃 + 服务端无 seq 放弃 | 我们只有 `seqGate` 去重，没有退出条件 |
| 终态对账 | 前缀增量拼接 / 滞后聚合保护 / 真修正才 replace（三分支） | 我们是整段覆盖或整段追加 |
| 伪终态 | `failed` + 空 error + `turn_exit_reason=budget_exhausted` → `wrapped_up`（只出提示） | 我们按 `failed` 一律报错 |
| 断流期审批 | `pending_controls` 作为唯一真相做增删 + `prompt_id` 集合防复活 | 我们靠 SSE 事件，断流期产生的卡片会丢 |
| `unknown` 状态 | 必须发 `resolve-unknown`（带 `admission_id`+`execution_generation`），否则该 session 后续轮次被服务端挂起 | 我们没实现 |
| 错误模型 | layer/kind/retryable/action/resetsAt 五元组 + 查表出策略，消费 `Retry-After`（≤3600s） | 我们是"错误 → 一句话" |

**许可证边界**：Conduit 是 GPL-3.0，属于传染性协议。**只允许借鉴机制与常数语义，禁止复制其代码、注释、命名结构**。写入代码时需在 PR 描述中注明"机制参考 Conduit（口头语义），实现独立"。

### 2.2 iHermes（Expo/RN，MIT）——可借鉴实现

| 机制 | 价值 | 我们的差距 |
|---|---|---|
| `think` 标签全量重解析 + 已渲染长度取差（`App.tsx:2276/2306`） | 天然免疫"标签被 chunk 劈开"，比状态机增量切分稳 | 我们只有 `parts[0]` 经验拆分，已踩过坑（ChatVM 1377-1381） |
| 多键候选池 + BFS 提取正文/推理（9 个推理键、4 个正文档、120 次迭代上限） | 接第三方 OpenAI 兼容端点时的适配层 | 我们只认原生事件名，零宽容度 |
| 工具事件人类可读化（白名单字段拼装 + 安全序列化） | 直接展示原始 JSON 对用户无意义 | 我们的 `ToolStep.preview` 粒度粗 |
| 过程数据按消息归档（内存态 + `byMessage` 持久态） | 历史消息能回放"这条回答怎么来的" | 我们只有全局 `steps`，翻历史看不到轨迹 |
| **反面清单** | 整请求 180s 超时 / fetch 路径不收尾 flush / 无任何重连续传 / 只写不读的死状态 | 这三样我们都已经做得比它好，**不要退回** |

---

## 3. 重构设计

### R0 双通道并行：轮询做基线，SSE 做增强（本设计的核心）

**问题**：现有链路是"先试 SSE，失败了再轮询"。在鸿蒙流式不稳的前提下，这条链路的最坏路径是 `SSE 无帧 → idle 判定（现 30s）→ 退避 → getRun`，用户看到的是"转圈很久然后突然出结果"——慢的根因不是模型慢，是**第一份可用数据排在两级失败之后**。

**设计**：

1. **建 run 成功即刻双开**，两条通道互相独立、互不阻塞：
   - **通道 A（基线，永远开）**：`getRun` 轮询，产出**快照**。
   - **通道 B（增强，尽力开）**：`GET /events` SSE，产出**增量**。
2. **SSE 可用性判据（不与"首字"绑定）**：
   - **可用** = 建流后 `T_open = 3s` 内拿到 HTTP 响应且至少收到 **1 帧**（`id:`/`data:` 事件帧**或** `: open` 注释帧/心跳帧均可）。**不要求 typed 事件**——模型思考 20s 后才吐字是正常情况，不能因此把健康流杀掉。
   - **判死** = 连续 `15s` 收不到**任何字节**（无心跳、无事件）→ 关流并回落轮询。
   - **重连预算（全项目唯一一套；§R3 只引用本节，不重复定义）**：无进展 3 次 / 全程 50 次 / 重连间隔 1s；HTTP 404 或服务端不提供 `seq` → 不再重连；距上次失败 ≥15s 时允许**一次**救援重试（跨网抖动），仍失败则本 run 内不再重试。
3. **单次请求预算与"在飞跳过"（本节最容易被忽略、但决定成败）**：

   - 每次 `getRun` 带**硬上限 3s**，由统一 ticker 到点 `httpRequest.destroy()`；**不依赖 SDK 的 `readTimeout`**（`RunsApi.ets:43` 实测对半开连接无效）。
   - 上一轮 `getRun` 尚未返回 → **跳过本轮 tick**，不排队、不叠加。否则"单次挂 120s × 2s 节奏排队"会把请求堆成雪崩。
   - 并发不变量：**同一 run 在飞请求 ≤1**（SSE 订阅与 `getRun` 各算一类，互不阻塞）。
   - ticker 自检：`>3s` 未推进一 tick → 判定主线程卡住，打点并降级（见 §R14）。

4. **轮询节奏（自适应、可配）**：

   | 窗口 | 间隔 | 说明 |
   |---|---|---|
   | run 创建后 0–15s | **2s** | 起步值（不再用 1s，避免请求过密）；按实测 P50/P95 再调 |
   | 15–60s | 2s | 常规推进 |
   | >60s | 5s | 长任务省请求 |
   | 连续 3 次 output 无变化 | 间隔 ×2（上限 10s） | 空转自降频 |
   | `status` 非 active（终态） | 立即收口 | 不等下一次 tick |
   | 进入后台 | 停轮询；回前台立刻补一次 | 省电 |

5. **SSE 一旦可用**：轮询降频到 10s，只做对账；渲染交给增量。SSE 中途判死（15s 无字节）→ 回落到 2s 轮询，**不等待 idle 超时**。
6. **统一渲染入口**：两条通道都汇到 `applyDelta(text)` 与 `applySnapshot(run)`。快照按**前缀差量**渲染（只追加比已渲染文本多出来的部分），视觉上仍是"逐步长出"，但语义是快照。
7. **两条验收口径必须分开（不要混成一条）**：
   - **UI 可见进展**：建 run 返回后 ≤1.5s 必须出现可见状态（"已提交 / 等待模型 / 已接收 N 字"）。**与模型无关**，只依赖 `POST /v1/runs` 的返回。
   - **首个非空快照内容**：≤5s（P50）/ ≤10s（P95）。这条**受模型首字速度制约**，列为优化目标与观测指标，**不作为硬门槛**——模型 20s 才吐第一个字时，客户端没有可优化的空间。
8. **模式明示**：状态条显示 `实时` / `快照` / `重连中`，不假装逐字。这是产品诚实性要求，也是排障入口。

**为什么这样就快了**：把"首份数据"的最坏路径从「SSE 失败 + idle 30s」压到「一次 getRun」，并给单次 getRun 加上 **3s 硬上限**——即使跨机查询挂起，也会在 3s 内被打断并进入下一个节奏，不会把 2s 的节奏拖成 120s。

**代价与缓解**：

| 代价 | 缓解 |
|---|---|
| 请求数上升（基线 2s 一次） | `getRun` 是无副作用读操作；配合"无变化翻倍"把长任务压到 5–10s 一次 |
| 耗电 | 仅前台快轮询；后台停 |
| 两条通道可能给出不一致文本 | 统一入口 + 前缀差量合并（§R4），并在终态做一次权威对账 |

**验收**：
- **SSE 全断**（用防火墙/代理人为丢弃 events 流）：UI 可见进展 ≤1.5s（P50）；首个非空快照 ≤5s（P50）/≤10s（P95）；全程能推进到终态。
- **`getRun` 半开**（人为挂起不返回）：单次 3s 内被 `destroy`，界面 5s 内进入"网络不稳 · 快照"状态，**并发在飞 ≤1**、无请求堆积。
- **SSE 正常**：逐字体验不变，轮询自动降频（可通过日志确认节奏切换）。
- 两种模式下终态文本一致。
- **调优闭环**：以 `docs/test-reports/latency-baseline.md` 记录不少于 20 次真实发送的 `t_create / t_first_frame / t_first_token`，间隔只按该表调，不凭感觉改常数。

**三段耗时埋点（用于回答"到底慢在哪"）**：每次发送记录 `t_create`（POST 返回）、`t_first_frame`（首个 SSE 帧或首个快照非空）、`t_first_token`（首段模型文本）。三者分开记，才能区分"客户端慢"与"模型慢"——模型侧首字 20s 的，任何客户端优化都救不了，必须如实显示"等待模型"。埋点脱敏后写日志，可在设置页的诊断区查看最近 20 次。

**不做什么**：不引入 WebSocket（gateway 无 runs 的 WS 端点，加了就要改 gateway）。

### R1 流式层：摸清 SSE 的可用边界（不再以"修好"为目标）

**定位变化**：R0 之后，SSE 只是增强通道。R1 的目标从"修好 SSE"降级为"**摸清它在什么条件下能用、什么时候该立刻放弃**"，避免把工期押在鸿蒙内核的成熟度上。
**问题**：跨机服务端正常（§1.2）而 App 收不到数据，说明问题在 `ApiClient.openStream` 的 `requestInStream` 用法。

**设计**：
1. **先补一张四格差分矩阵**（审爷指出：原嫌疑集只怀疑 SSE，漏了"非流式请求也可能挂"这个反例，与 §1.2 自身证据矛盾）：

   | | 本机 loopback | 跨机 LAN |
   |---|---|---|
   | `GET /v1/runs/{id}/events`（SSE） | 待测 | **已实测 OK**（0.07s 首字节，§1.2） |
   | `GET /v1/runs/{id}`（getRun） | 待测 | **待测（关键）** |

   跨机 `getRun` 这一格必须单独测：若它也慢/挂，则 §R0 的"轮询基线"不成立，必须回到 §6 的兜底口径（降频 + 提示"网络不稳" + 可重开取回），**不得直接进 S2**。
2. 建立**最小复现夹具**：一个只做三件事的页面（建 run → 触发订阅或查询 → 打印首字节时刻/累计字节/结束原因），不经过 ChatVM 任何逻辑。目的：把"链路收不到"与"VM 状态机有问题"彻底分开。
3. 按嫌疑度依次验证四件事，每件都要有可复现结论才动主链路：
   - `expectDataType: ARRAY_BUFFER` 与 chunked 响应的兼容性；
   - `dataReceive` 回调的注册时机（是否必须早于 `requestInStream`）；
   - `dataEnd` 是否在首块到达前抢跑；
   - `destroy()` 之后回调是否悬挂（旧请求的回调打到新流上）。
4. 只有夹具证明"某一种用法稳定收到增量"之后，才把该用法回填 `ApiClient`。

**SSE 优化清单（逐条落到模块，来源已核到行号）**：

| # | 机制 | 来源 | 我们现状 | ArkTS 落点 |
|---|---|---|---|---|
| 1 | 跨 chunk 字节缓冲 + 空行切帧 + 保留半截帧 | iHermes `parseAndDispatchSseBlocks`（`split` 后 `pop()` 回存，App.tsx:1932）；Conduit `SseFrameScanner.addChunk/close`（stream_parser.dart:56-74） | **已有且更严**：`SseParser.feed(ArrayBuffer)` + UTF-8 边界残字节 | 保持；补 `close()` 冲刷尾帧（iHermes 的 fetch 路径正好漏了这步，别学） |
| 2 | 握手期 / 存活期 / 绝对上限三件事分离 | Conduit `guardHermesEventStream`（api:407-494） | 只有单一 idle | `StreamGuard`：**握手 3s**（拿响应 + ≥1 帧，§R0-2）、**判死 15s 无任何字节**、**绝对上限 30min**。三者语义不同，**禁止混用一个常数**（混用即误杀健康流） |
| 3 | `seq` + `Last-Event-ID` 续帧 | Conduit `_resumableHermesRunEvents`（transport:1380-1449） | 有 `seqGate` 去重，**无退出条件** | 实现点：`SseParser.gateSeq` 旁加 `resumeAttempts`；`RunsApi` 抛错保留 HTTP 码以识别 404。**重连预算见 §R0-2（全项目唯一一套），此处不重复列数值** |
| 4 | Conduit 的"心跳不续命"**只适用于 typed-idle** | Conduit（api:404-406） | — | **本设计改用字节级判死**（15s 无任何字节），心跳/注释帧**计入有效字节**。**不得**沿用"心跳不续命"的口径——与 §R0-2 的握手判据叠加会把健康流在 3s 内误杀 |
| 5 | 多字段增量归一（正文档 4 键 / 推理 9 键 + BFS + 迭代上限） | iHermes `extractContentTexts`（2219）/ `extractReasoningTexts`（2142） | 只认 `message.delta`，零宽容 | 新增可选适配层 `net/OpenAiCompatSse.ets`；**主链路 `SseParser` 保持零猜测** |
| 6 | `think` 标签全量重解析 + 已渲染长度取差 | iHermes `splitThinkingFromText`（2276）/ `consumeThinkingDelta`（2306） | 只有 `parts[0]` 经验拆分（已踩坑） | `model/ThinkingSplitter.ets`，接在 content 写入前 |
| 7 | 工具失败不 fail 整轮；`error: "False"/None/0` 视为无错 | Conduit `hermesErrorIsTruthy`（parser:929） | 可能 `if (d.error)` 误判 | `ErrorModel` 增加 truthy 归一 |
| 8 | `approval.responded` 不生成新卡，`*.settled` 才关闭 | Conduit `_approvalOutcomeEvents`（parser:1017-1024、516-527） | 未知 | `ApprovalHub`：事件名黑名单 + `prompt_id` 集合 |
| 9 | 终态文本抽取（跳过 function item / commentary，带深度与节点上限） | Conduit `extractHermesOutputText`（683-755） | `String(out)`，多 item 丢内容 | `model/OutputText.ets`（§R4） |
| 10 | 双通道共用同一解析器 + 同一缓冲状态 | iHermes（fetch 与 XHR 共用 `parseAndDispatchSseBlocks`，1932） | `feed(ArrayBuffer)` 已是该形态 | 保持契约；新通道只负责"分片→ArrayBuffer" |
| 反 | 整请求 180s 超时 / fetch 不收尾 / 无重连续传 / 只写不读的死状态 | iHermes | 我们已优于它 | **不回退** |

许可证：Conduit 为 GPL-3.0，**只借机制与常数语义，不复制代码/注释/命名结构**；iHermes 为 MIT，可借鉴实现但仍在 PR 里标注来源。

**验收**：夹具在模拟器与真机上各跑 10 次，首字节中位数 ≤2s、无一次零字节结束；同一 run 的 SSE 与 getRun 终态文本一致。

**不做什么**：不引入 WebSocket（gateway 无 runs 的 WS 端点，加了就要改 gateway）。

### R2 状态机：把布尔堆换成显式状态

**问题**：`streamPolls` / `streamGen` / `terminalReceived` / `busy` / 各 `pending*` 布尔量共同表达"当前处在哪一步"，一致性靠注释维持。

**设计**：定义单一 `RunPhase` 枚举与唯一转移函数。

```
idle
 ├─create→ creating ─ok→ streaming ─┬─terminal→ terminal(completed|failed|cancelled|canceled|stopped|interrupted|incomplete)
 │                                   ├─握手失败(3s 无响应/无帧) 或 15s 无字节→ degraded_polling
 │                                   └─SSE 已出帧后断流→ recovering ─┬─续订成功→ streaming
 │                                                                   └─放弃→ degraded_polling
 ├─用户停止→ stopping → terminal(cancelled|stopped)
 └─(正交子状态) approvalPending = true/false —— 审批挂起**不是** phase

degraded_polling ─┬─status 终态→ terminal(...)
                  ├─出现 pending_controls→ approvalPending=true，继续轮询
                  └─(可选)SSE 恢复→ streaming
```

规则：
- **每个阶段只允许一个在飞的请求**；进入新阶段先取消旧阶段的 token（取消传播链显式写）。
- **`terminal` 的枚举必须与 `Run.ets:38 isTerminalStatus()` 逐字一致**（现在实现里已有 `stopped` / `interrupted` / `incomplete`，图里不许只写三个）。
- **审批挂起是正交子状态，不是 phase**：`waiting_approval` 不能作为独立状态，否则 `degraded_polling + 审批` 这种真实组合无法表达（断流期间照样会冒出审批卡，见 §R5）。
- `approvalPending` 期间**只允许状态查询与审批应答**，禁止重放创建类请求（否则会跑两遍）。
- `degraded_polling` 与 `streaming` 的 UI 必须可区分（用户要知道"现在是快照不是逐字"）。
- **`degraded_polling` 必须有出边**（到 terminal / 回 streaming），不允许出现死端。
- 所有阶段转移打一条结构化日志（phase / approvalPending / run_id / seq / 原因），脱敏。

**验收**：状态转移表逐条有单测；任意两条转移路径并发注入（如"用户停止"与"SSE 终态"同时到达）不产生双终态。

### R3 放弃条件：由 `status` 决定，不由墙钟决定

**问题**：现有实现用两个墙钟（150s / 600s）表达"该不该继续等"，于是出现两个反向缺陷——长任务（5–6 分钟）被 150s 提前掐断，死 run 要白等 600s。R0 之后轮询节奏已由 §R0 的节奏表接管，本节只管**什么时候彻底放弃**。

**设计**（借 Conduit 语义，数值按内网实测调整）：

| 判据 | 规则 |
|---|---|
| `status` 为终态 | 立即收口（终态集合：`completed` / `failed` / `cancelled` / `canceled` / `stopped` / `interrupted` / `incomplete`，与 §R2 及 `Run.ets:38` 逐字一致） |
| `status` 仍为 active | **继续轮询，不设墙钟**——这是长任务能跑完的唯一保证 |
| 连续 `K=3` 次 getRun 均失败（网络/超时） | 判定链路断，收口并提示"连接中断，可重试"，**不谎报任务失败** |
| 连续 `M=3` 次返回未知状态 | 判定协议异常，收口并附诊断码 |
| 用户主动停止 | 发 `stop` → 以服务端终态为准；服务端不回则本地收口（标注"可能仍在运行"） |
| SSE 重连 | **见 §R0-2（唯一一套预算；本节不重复任何数值）** |
| 应用进后台 | 停轮询；回前台立刻补一次并续上节奏 |
| 绝对上限（30min）触发 | **不判 failed**：落"已中断·任务仍在服务端"，给"重开取回"入口；文案不得出现"失败" |

关键点：**只要服务端还说"在跑"，就一直等；一旦服务端说"不在跑"或查询连续失败，立刻收口。** 这同时解决"掐长任务"与"白等死 run"。

保留：用户可配的 `recover_poll_interval_ms` 作为节奏表的上限覆盖（用户设了 30s 就尊重 30s），避免破坏已有设置。

**验收**：三个场景的真实 run —— 短任务（<10s）、长任务（5–6 分钟）、人为 kill 的 run —— 各自在预期时间内收口，且长任务不被提前掐断。


### R4 终态对账：不要裸 append，也不要裸 replace

**问题**：`output` 在多 item 时不是字符串；直接 `String(out)` 会丢内容；直接覆盖会截断已渲染文本。

**设计**：
1. `extractOutputText(raw)`：显式栈遍历，跳过 function item 与 commentary 阶段，带 `maxChars/maxDepth/maxNodes` 三限量与环检测。
2. 合并三态：**先剔除 reasoning/thinking 段再比较**（否则 `output` 只含正文、`streamed` 含正文+推理，前缀判定必败 → 落到 replace → 正是要避免的截断）；剔除后：
   - `streamed` 是 `output` 的前缀 → 只 append 差量；
   - `output` 是 `streamed` 的严格前缀（滞后聚合）→ **不截断**，保留已渲染；
   - 等长但不同（模型重新生成）→ 以 `output` 为准 replace，并保留旧文本进"上一版"可回看；
   - 其余 → replace。
3. 伪终态：`failed` + 空 error + `turn_exit_reason` 以 `budget_exhausted` / `max_iterations_reached(` 开头 → 渲染成"已达步数上限，以下是已完成的输出"提示，不报错。

**验收**：构造三类夹具（多 item output / 滞后聚合 / budget 伪终态）各一条断言。

### R5 审批与提问：以服务端列表为唯一真相

**设计**：
- 每次 getRun / 重连成功，用 `snapshot.pending_controls` 做增删对账（列表即真相），不依赖 SSE 事件补历史。
- 已关闭的 `prompt_id` 进 `closedSet`，防止 `approval.responded` 之类事件把卡片弹回。
- `answerClarify` 与 `approval` 用同一套 `request_id + execution_generation + choice`；`stale_generation` 视为"已被回答或已过期"，不重试。
- 倒计时只做显示，真值以服务端为准；`APPROVAL_TIMEOUT_SEC=60` 改为**从设置页读取的服务端超时值**（默认 60，可调），并在到期后主动拉一次 snapshot 确认，而不是本地直接判死。

**验收**：审批窗口内答完 / 超时后答 / 断流期间产生审批 三条路径各一条用例。

### R6 `unknown` 状态收口

**设计**：`snapshot.status == unknown` 时，发一次 `POST /v1/runs/{id}/resolve-unknown`（带 `admission_id` + `execution_generation`）。`receipt.outcome == completed` → 多读一轮拿答案；其余 → 判 `interrupted`。该调用 best-effort，永不抛。

> **端点已核实存在**（审爷要求验证）：`gateway/platforms/api_server.py:70` 注册了 `("run_unknown_resolution", ("POST", "/v1/runs/{run_id}/resolve-unknown", "run_unknown_resolution"))`；`api_server_authority_runs.py:73` 注释亦确认"`unknown` 不是终态，后续轮次在等这次确认"。客户端只需在 404 时**跳过该步并本地判 `interrupted`**，不报错。

**验收**：人为制造 `unknown`（服务重启中断一个 run）后，新消息能正常发出（不被服务端挂起）。

### R7 错误模型：五元组 + 文案分离

**设计**：
```
classify(err) -> { layer, kind, retryable, action, resetsAt, severity }
```
- `layer`：provider / endpoint / streaming / auth / gateway / runtime
- `kind`：connection / timeout / auth / rate_limit / context_overflow / not_found / busy / unknown
- `action`：retry / retryAtReset / reauth / openSettings / newChat
- `resetsAt`：来自 `Retry-After`（上限 3600s）
- `severity`：`blocking`（会话无法继续）/ `degraded`（可继续但有损）

> **本文对错误模型的唯一定义就在本节**。§R10 的 #7（错误三层呈现）与 #8（`severity`）**已并入此处**，不另立字段或第二套口径；`ErrorModel` 是唯一实现点，UI 只消费该结构。

UI 只消费结构，文案在 i18n 层。**铁律：气泡已有内容时，错误不得覆盖内容**——降级为行内状态条 / 顶部提示条。

**验收**：14 类错误码各一条渲染断言，重点验"有产出时错误不吞内容"。

### R8 拆分（结构目标）

```
viewmodel/
  ChatVM.ets            编排：只做"用户意图 → 调用哪条链路"，目标 ≤600 行
  stream/StreamRunner.ets  建流/订阅/重连/守卫（R1/R3）
  stream/RunTracker.ets    状态机（R2）
  approval/ApprovalHub.ets 审批对账（R5）
net/
  ApiClient.ets         HTTP 原语
  SseParser.ets         分帧（保持 feed(ArrayBuffer) 契约）
  RunsApi.ets           REST 封装（补齐 resolve-unknown / stop / steer）
  ErrorModel.ets        R7 分类器
model/
  Run.ets               快照 DTO（补 error / turn_exit_reason / pending_controls）
  ThinkingSplitter.ets  think 标签切割（借 iHermes 语义，MIT 可用）
  OutputText.ets        extractOutputText（R4）
components/
  MessageList / Bubble / Composer / ToolSteps / ApprovalCard / StatusBar
i18n/
  Translations.ets      扁平 key + 语言解析（device/zh/en）
```

`ChatPage` 目标 ≤300 行：只做布局，不含业务判定。

### R9 过程数据按消息归档

`ChatMessage` 增 `processEntries`；`DbHelper` 增一列（JSON）或一张 `message_process` 表。翻历史消息能看到当时的工具流水与推理摘要。

**验收**：发一条会调用工具的消息 → 回溯列表 → 该消息带完整步骤；清理旧会话后不残留孤儿行。

### R10 产品与工程层借鉴（传输之外的优点）

前面 §R1 只讲了传输机制。两个项目在**交互与工程组织**上还有一批可直接用的东西，逐条给优先级与落点（来源均已核到文件行号）。

| # | 借鉴点 | 来源 | 为什么值得 | 优先级 | 落点 |
|---|---|---|---|---|---|
| 1 | **思考骨架屏**：shimmer 循环 + 三行不等宽占位 | iHermes `chat_bubble.tsx:146-176` | 首字未到时给"正在思考"的视觉占位，**把"慢"的体感变成可控的等待**——正好承接 §R0 的"等待模型"状态 | **P0** | 新增 `components/ThinkingSkeleton.ets`，在 `t_first_token` 之前替代空气泡 |
| 2 | 气泡入场：淡入 + 上移 10px | iHermes `chat_bubble.tsx:64-72` | 新消息有节奏感，成本极低 | P1 | `animateTo({ duration: 220, curve: Curve.EaseOut })` |
| 3 | 过程面板：默认折叠 + 条数 + "（进行中）" | iHermes `chat_bubble.tsx:114-139` | 工具流水不占屏，点开看细节；与 §R9 过程归档配对 | P1 | `components/ToolSteps.ets` |
| 4 | **20 个语义色槽 + 两套主题 + 圆角/描边档位** | iHermes `tokens.ts:3-83`（bg/blobTop/blobBottom/ink×3/border×2/card×4/inputBg/气泡/按钮×2/状态×3） | 我们 `theme/Accent.ets` 只有 104 行、主色型；直接做深色模式会散落硬编码 | P1 | 扩成 `ThemeTokens` + light/dark 两套，页面禁止直写颜色 |
| 5 | **i18n：扁平词条 + `as const` 编译期查缺 + `device` 跟随系统** | iHermes `translations.ts:2/259/261`（254 词条） | 开源必需；`as const` 是防漏词条的最低成本手段 | **P0（开源门槛）** | 新建 `i18n/Translations.ets`；业务状态只存 key，不存文案 |
| 6 | 连接探活**降级链**（多路径依次试，保留 lastError） | iHermes `client.ts:27-45` | 抹平网关版本差异，比"要求用户升级"实际 | P2 | `ApiClient.ping()` 多路径尝试 |
| 7 | **错误分三层呈现**（阻塞 Alert / 行内状态条 / 气泡内），且错误不覆盖已有内容 | iHermes `App.tsx:822/830` | 用户已读 300 字时不能被一句错误清空 | **P0** | **已并入 §R7**（三层分工写在那里，此处不重复定义） |
| 8 | 错误加 `severity = blocking / degraded`（会话还能不能继续） | Conduit `hermes_error_surface.dart:69、425-435` | 比 layer/kind 更贴近用户问题"我还能接着聊吗" | P1 | **已并入 §R7**（作为第 6 字段统一定义） |
| 9 | **后台续跑租约**（移动端把流挂到后台任务上续跑） | Conduit `background_streaming_handler.dart:150-588` | 审批窗口 60s 内切后台不该断 | P1（**先做能力探针**） | **先探针**：确认当前 SDK/目标机型的长时任务能力与配额；探针通过再实现，不通过则降级为"回前台立刻补一次快照" |
| 10 | 上下文用量报告 | Conduit `hermes_work.dart:272` | 技术用户关心上下文占用 | P2（**数据源待核**） | 先确认 gateway 是否有端点返回 token 用量；**未确认前不实现**，避免编造字段 |
| 11 | 房间式多 agent 协作 | Conduit `hermes_rooms.dart`、`hermes_room_page.dart` | 与未来多 agent 方向契合，但当前超出范围 | P2（只记录，不做） | — |
| 12 | 桌面 WebSocket 第二传输 | Conduit `hermes_desktop_transport.dart` | 需要 gateway 提供 WS 端点 → 违反本设计边界 | **不做** | — |
| 13 | 通用动效控件集（卡片/按钮/Tab） | iHermes `ui.tsx:7/47/94/112` | 一致性有价值，但鸿蒙有系统组件，照抄意义有限 | P2 | 按需 |

**反面清单（明确不抄）**：

| 反面项 | 来源 | 原因 |
|---|---|---|
| `toolSteps` / `chatPhaseText` **只写不读**（状态机半成品，UI 从不渲染） | iHermes `App.tsx:132/134`（grep 仅命中声明） | 会造成"看起来做了功能，实际没上屏" |
| Web 端 apiKey 明文进 `localStorage`、输入框去掉了 `secureTextEntry` | iHermes `kv.ts:15`、`App.tsx:1258` | 我们已有 HUKS，**不得降级** |
| 整请求 180s 超时、fetch 路径不收尾 flush | iHermes `App.tsx:75/1774-1790` | 长回答必被掐断；末帧丢失 |
| 字符串层 `split` 无长度上限的缓冲 | iHermes `App.tsx:1949` | 网关不 flush 时内存无限增长 |

**许可证边界（写进 CI）**：Conduit 为 GPL-3.0，**只借机制与常数语义**；仓库加一道 `tools/gpl-guard.py`：对 `.ets` 源文件做 Conduit 标识符/注释片段指纹扫描（如 `_resumableHermesRunEvents`、`hermesErrorIsTruthy` 等私有名不得出现），命中即失败。

> **口径限定**：该守卫只覆盖"标识符/注释级复制"这一最低级形态，**不构成法律保证**——结构级改写（同一算法换名重写）它识别不了，仍需人工复核。故 §7-6 的表述是"**降低风险**"，不是"合规保证"。iHermes 为 MIT，可借鉴实现但须在 PR 描述标注来源文件与行号。

### R11 UI 视觉体系重构（布局 / 样式 / 色系）

**先给实测数据**（`entry/src/main/ets` + `resources/base/element/color.json`，2026-11-18）：

| 项 | 现状 | 问题 |
|---|---|---|
| 字号档位 | **12 档**：10/11/12/13/14/15/16/17/18/32/36/40；`fontSize(13)` 用了 **57 次**、12 号 32 次、14 号 20 次 | 没有字阶，13 号既当正文又当标签，主次全靠感觉 |
| 颜色口径 | `color.json` 有 **23 个语义槽**，但页面另散落 **37 处裸 hex**（`#757575`×4、`#212121`×4、`#F44336`×3、`#EEEEEE`×2、`#E0E0E0`×2…） | **两套口径并存**，改一处色要 grep 全仓；深浅色无法统一控制 |
| 深色模式 | `resources/` 下**无 `dark/` 目录**；而 `start_window_background` 是 `#10131A`（深），页面 `bg_page` 是 `#FAFAFA`（浅） | 深色模式完全缺失，且启动瞬间"黑→白"跳色 |
| 间距 | padding 出现 4/6/8/10/12/16（含 6、10 这类非 4 倍数） | 无 4pt 网格，视觉节奏散 |
| 气泡宽度 | 大量 `.width('100%')`（含为修溢出而补的，见 `ChatPage.ets:1141` 注释） | 气泡全宽 → 行过长难读、用户/助手区分弱 |
| 主题色 | 6 套 accent 预设，只有 `primary` + `tint` 两值；结构色在 color.json | 深色下 `#E3F2FD` 这类浅 tint 会刺眼，且 accent 不参与深色适配 |

**实测对比度（WCAG 公式，双底色都算）**——这不是审美问题，是**当前就有 5 个语义色不达 AA**：

| 语义槽 | 现值 | on `#FAFAFA` | 判定 | 建议值 | 新对比度 |
|---|---|---:|---|---|---:|
| `text_primary` | `#212121` | 15.43 | ✅ | 不变 | — |
| `text_secondary` | `#757575` | **4.41** | ❌ | `#616161` | 5.93 |
| `text_hint` | `#9E9E9E` | **2.57** | ❌ 严重 | `#6E6E6E` | 4.89 |
| `danger` | `#E53935` | **4.05** | ❌ | `#C62828`（复用 `danger_deep`） | 5.39 |
| `warning` | `#EF6C00` | **2.95** | ❌ 严重 | `#A85B00` | 4.83 |
| `success` | `#2E7D32` | 4.91 | ✅ | 不变 | — |
| accent[0] 配白字 | `#1E88E5` | 3.68 | ❌ | `#1565C0` | 5.75 |

> 其余 5 套 accent 配白字均 ≥5.13（`#00838F` 4.52、`#6A1B9A` 9.39、`#C2185B` 5.87、`#283593` 10.39、`#2E7D32` 5.13），**只有 0 号 `#1E88E5` 需要换**。

**设计目标（可机械验收，不写"更美观"这种形容词）**：

1. **单一口径**：页面**禁止**出现裸 hex；所有颜色只从 `color.json` 语义槽取。现有 23 槽保留，**补 6 槽**：`bg_elevated`、`border_soft`、`accent_soft`、`text_on_accent`、`scrim`、`focus_ring`。Accent 6 套预设扩展为 `{ light: {primary,tint}, dark: {primary,tint} }`。**同时按上表换值**：5 处不达 AA 的颜色必须替换（不是可选项），否则改完仍不合格。
2. **深色模式**：新增 `resources/dark/element/color.json`（键集合与 base **完全一致**，由系统限定词自动切换）。深色基线：`bg_page #121417`、`bg_card #1B1E23`、`text_primary #E8EAED`、`text_secondary #A6ADB8`、`divider #2A2F36`，accent 取 `-200/-300` 级而非 `-50` 级。**注意：深色下 accent 是浅底，所以 `text_on_accent` 必须取深墨 `#0F1216`，不能沿用白字**——浅底配白字对比度必然 <4.5:1。
3. **字阶收敛到 6 档**：`display 28` / `title 20` / `body-lg 16` / `body 14` / `caption 12` / `micro 11`。映射规则：正文一律 14（不再用 13）；辅助信息 12；11 只允许用于时间戳/计数且对比度须 ≥4.5:1。页面禁止裸写数字，统一从 `theme/Typography.ets` 取。
4. **间距 4pt 网格**：只允许 `4 / 8 / 12 / 16 / 24 / 32`；现行 6、10 全部归一到 8 或 12。
5. **布局**：
   - 气泡最大宽度 **78%**（用户靠右、助手靠左），正文可读宽度控制在一行 ≤34 汉字；超宽表格/代码块允许横向滚动而不撑破气泡。
   - **顶部状态条**（常驻，承接 §R0）：`● 实时` / `◐ 快照` / `⚠ 重连中` + 已用时；这是把"稳不稳"变成可见信息的关键，目前完全没有。
   - **审批卡吸附**在输入区上方（不随消息滚出视野），倒计时环 + 44pt 主按钮；卡片出现时**顶部同时显示一条横幅**（防止用户在列表中间漏看）。
   - **工具流水默认折叠**为一行摘要（`工具 3 步 · 进行中`），点开展开（§R10-3）。
   - 输入区：safe-area 内边距 + 键盘避让 + 所有可点区域 ≥44×44。
6. **无障碍底线**：正文对比度 ≥4.5:1、大字 ≥3:1（WCAG AA）；支持系统字体缩放（禁止写死 px 高度包文字）；颜色不作为唯一状态载体（实时/快照同时有图标+文字）。

**改动点**：

| 类型 | 内容 |
|---|---|
| 新增 | `theme/Typography.ets`（6 档字阶）、`theme/Spacing.ets`（6 档间距）、`resources/dark/element/color.json`、`components/StatusBar.ets` |
| 修改 | `resources/base/element/color.json`（+6 槽）、`theme/Accent.ets`（每预设加 dark 变体）、`ChatPage.ets` / `SettingsPage.ets` / `ScanPage.ets`（去裸 hex、去裸字号、气泡限宽、间距归一） |
| **不改** | 现有 23 个槽的**键名**（避免全仓改引用）；既有页面结构与交互路径；accent 的持久化机制（`accent_index`） |

**验收（全部可机判）**：

1. `tools/ui-audit.py` 断言：`.ets` 内裸 hex 计数 **= 0**；裸 `fontSize(<数字>)` 计数 **= 0**；出现的字号值 ⊆ 6 档；padding 值 ⊆ 6 档。
2. base 与 dark 的 `color.json` 键集合**完全相等**（脚本比对，缺一即失败）。
3. 对比度脚本按 WCAG 公式算 `text_primary/bg_page`、`text_secondary/bg_page`、`text_on_accent/accent` 三对，两套主题各 ≥4.5:1（**深色下 `text_on_accent` 用深墨 `#0F1216`，不得用白**）。
4. 截图机判（`tools/shoot-emulator.py`）：浅色/深色各 4 张（会话列表 / 对话 / 审批卡 / 设置），断言状态条文案存在、气泡宽度 ≤78%、审批卡在输入区上方。

### R12 性能

**实测**（2026-11-18）：

| 项 | 现状 | 影响 |
|---|---|---|
| 列表渲染 | `LazyForEach` **0 处**；`ChatPage.ets` 有 **10 处 `ForEach`** | 200 条会话全量构建，追加/滚动都是 O(n) 重建 |
| Markdown | `Markdown.ets:10` 注释自陈"**每次渲染全文重解析**" | 流式下每 token 一次 O(n) → 整条消息 O(n²) |
| 快照渲染 | §R0 后 2s 一次快照 | 每次快照触发全列表 diff + 全量重解析 |
| DB 写入 | `DbHelper` 已用 `beginTransaction/commit`（478-519） | 基本正确；缺 WAL 与索引 |

**设计**：

1. **消息列表虚拟化**：`LazyForEach` + `IDataSource`，key = `messageId`，只构建可视区 ±1 屏。
2. **Markdown 分段缓存**：按 `(messageId, text.length)` memo；流式时**只重解析最后一段未闭合内容**，遇到空行/代码块闭合即冻结该段缓存。
3. **渲染节流**：同一 run 的两次快照间隔 <500ms 时合并（只渲染最后一次）。
4. **首屏**：`aboutToAppear` 只读本地缓存，网络请求放 `onPageShow` 之后；**build 内禁止 IO / 计算**（已满足，保持）。
5. **图片**：解码前降采样到 ≤1080px、单图 ≤2MB、列表用缩略图，外加 LRU（≤20 张 / 50MB）。
6. **DB**：开 WAL；补复合索引 `(serverId, pf, role, sessionId, ts)`；消息分页加载（每页 50 条）。
7. **启动预算**：冷启动到首帧 ≤800ms（`accentInit` 已是异步不阻塞，保留）。

**验收**：200 条会话滚动帧率 ≥55fps；3000 字消息流式时主线程单帧 <16ms；冷启动到首帧 ≤800ms（连续 10 次 P50/P95）。

### R13 安全

**实测**：

| 项 | 现状 | 判定 |
|---|---|---|
| 凭据存储 | `TokenVault.ets:2/11` — HUKS AES-256-GCM，CMK **TEE 驻留不可导出**，系统缺 HUKS 时 fail-closed | ✅ **已达标，不动** |
| 传输 | `module.json5` **未显式声明 cleartext 策略**（grep 0 命中）；实际全走 `http://LAN:8377`，Bearer key 明文过网 | ⚠ 需显式化 + 文档写清 |
| 日志 | 未见直接打印 key/token（grep 未命中），但**没有任何断言防止回归** | ⚠ 缺门禁 |
| 备份 | 未见 `allowBackup` 配置 | ⚠ 待定 |

**设计（按威胁排序）**：

1. **传输边界的诚实处理**：内网 HTTP 是既定边界（上 TLS 需自签 CA 分发，超出本阶段）。补偿手段：① `module.json5` 显式声明 cleartext 策略并在 README 写明"**同网段嗅探即可拿到 key**"；② key 绑定 profile 且最小权限（guest 已关 22 项 toolsets）；③ 换 key 即旧码失效。
2. **凭据生命周期**：key 只存 HUKS；**不进入 `@State`、不进日志、不进崩溃上报**；401 一律走"重新扫码"，禁止静默重试；设置页提供"撤销本机凭据"（清 HUKS + 清本地会话）。
3. **二维码泄露面**：`--once` 打印后清屏已有；补 App 端扫码后提示"此码等同于密码"；若提供"粘贴 URI"入口，需提示**不要截图/发群**，且粘贴内容不回显 key。
4. **日志门禁**：所有日志走 `utils/LogSafe.ets`，对 `key|token|authorization|uri|password` 做掩码；CI 断言**裸 `hilog.` 调用数 = 0**（只允许 LogSafe 内部使用）。
5. **诊断导出**：默认脱敏（host → `192.168.*.*`、key → 前 4 位 + 长度），导出前二次确认，导出文件落应用沙箱不落公共目录。
6. **系统备份**：`allowBackup=false`（避免 HUKS 密文随系统备份流到无法解密的环境）。
7. **危险动作**：`stop` / 删除会话 / 清空历史需二次确认（审批卡本身即确认，不重复要求）。
8. **后台恢复**：从后台回前台时，审批卡**必须重新拉 snapshot** 再允许操作（防止用过期卡片误导用户批准）。

**验收**：`secret-scan` 0 命中（含 git 历史）；裸 `hilog` = 0；诊断导出样本经脚本扫描无 key 片段；401 路径端到端；`allowBackup=false` 在打包产物中核验。

### R14 健壮性

**实测**：

| 项 | 现状 | 影响 |
|---|---|---|
| 全局异常钩子 | `onUnhandledException` **0 命中** | 任一 ArkTS 异常直接闪退，且无日志可查 |
| 半开连接 | `RunsApi.ets:43-44` 自陈"跨机 getRun 挂 120s，`readTimeout` 对无数据半开连接**不生效**" | 请求永不返回，界面静默卡死 |
| 超时驱动 | `ChatVM` 多处 `setTimeout` 竞速，注释自陈 ArkTS 下**不可靠** | 看门狗可能不触发 |

**设计**：

1. **全局错误边界**：`EntryAbility` 注册 `onUnhandledException` → 结构化落盘 + 下次启动提示"上次异常退出"，附带阶段与 run_id（脱敏）。
2. **单一 ticker**：一个 1s `setInterval` 驱动**全部**超时/倒计时/轮询调度；每个任务登记 deadline 由 ticker 检查；禁止嵌套 `setTimeout`。ticker 自带心跳自检（>3s 未推进 → 判定主线程卡死并打点）。
3. **半开连接强制中断**：所有请求登记 deadline，ticker 到点直接 `httpRequest.destroy()`；**不依赖 SDK 的 readTimeout**。
4. **重试令牌桶**：全局 30 次/分钟上限；超限进入"链路不稳"态并降频——断网时既不打爆服务端也不耗电。
5. **数据层韧性**：迁移幂等（版本号 + 表存在检查）+ 迁移前备份 + 失败回滚；DB 损坏时降级"只读 + 提示重建"，不闪退。
6. **崩溃续接**：`run_id` 在**发起订阅之前**落库；启动时扫描"未完成 run"并续接或收口（需核对当前实现是否已如此）。
7. **解析宽容**：所有 JSON 解析 try/catch + 字段缺省；响应 >8MB 截断并提示。
8. **网络切换**：Wi-Fi↔移动网络/切网段 → 立即作废在飞请求并重订阅，不等超时。

**验收**：注入 8 类故障各一条用例 —— 断网 / 半开连接 / 极慢响应 / DB 损坏 / JSON 截断 / 崩溃重启 / 切网 / 内存压力；连续 30 分钟长任务不掉线不崩；异常日志能定位到阶段与 run_id。

---

## 4. 改动点清单

| 类型 | 内容 |
|---|---|
| 新增 | `viewmodel/stream/`、`viewmodel/approval/`、`net/ErrorModel.ets`、`model/OutputText.ets`、`model/ThinkingSplitter.ets`、`utils/LogSafe.ets`、`utils/Ticker.ets`、`utils/RetryBucket.ets`、`viewmodel/MessageDataSource.ets`（LazyForEach 数据源）、`components/*`（含 `ThinkingSkeleton`、`StatusBar`）、`theme/Typography.ets`、`theme/Spacing.ets`、`resources/dark/element/color.json`、`i18n/`、`tools/gpl-guard.py`、`tools/ui-audit.py`、`tools/shoot-emulator.py` |
| 修改 | `ChatVM.ets`（瘦身 + 状态机接入）、`ChatPage.ets`（组件化）、`RunsApi.ets`（补 resolve-unknown）、`model/Run.ets`（补字段）、`DbHelper.ets`（过程归档 + 迁移） |
| **不改** | `Hermes gateway` 任何文件、`TokenVault.ets` 的加密形态、`SetupUri.ets` 的 URI 协议（`hermespaw://setup/1`）、既有数据库既有列语义 |
| 保留 | `SseParser.ets` 的字节层分帧与 `seqGate`；用户可配轮询间隔；全部既有 selftest |

---

## 5. 实施顺序（每步独立可验）

| 步 | 内容 | 依赖 | 验收 |
|---|---|---|---|
| S1 | **R0 双通道基线**（在现有 `ChatVM` 上最小侵入接入并行轮询，不动其它结构） | **前置：四格差分矩阵（含跨机 getRun）实测通过** | UI 可见进展 ≤1.5s（P50）；首个非空快照 ≤5s（P50）；单次 `getRun` 3s 硬上限 + 在飞跳过 + ticker 自检均生效；长任务能跑完 |
| S1b | **R10 体感两件套**：思考骨架屏 / 错误三层呈现（后台续跑租约需先过能力探针，不进本步） | S1 | 首字前有骨架屏；错误不覆盖已有正文 |
| S2 | **R3 放弃条件**替换现有 150s/600s 墙钟 | S1 | 三场景 run 验收（§R3） |
| S3 | R8 骨架拆分（**只搬不改逻辑**），全 selftest 保持绿 | S1 | 文件行数达标、`git diff` 无行为变化 |
| S4 | R2 状态机接管 | S3 | 转移表单测 + 双终态注入 |
| S4b | **R13 安全闸门**（`LogSafe` + 裸 `hilog`=0 + `allowBackup=false` + 诊断脱敏） | S1 | 门禁脚本全绿；导出样本无 key |
| S5 | R1 SSE 边界摸底（夹具，产出"什么条件下可用"的结论） | S1 | 结论落 `docs/test-reports/sse-capability-matrix.md`；用于校准 `T_grace` |
| S6 | R4 + R6 + R7 | S4 | 夹具断言 + 错误矩阵 |
| S7 | R5 审批对账 + R9 过程归档 | S4 | 审批三路径 + 历史回放 |
| S8 | 主题 tokens / i18n 收口 / 开源门槛（含 `gpl-guard`、截图机判） | S7 | 见 §7 |
| S9 | **R11 UI 视觉体系**：色值换正 + 深色模式 + 字阶/间距归一 + 状态条/审批卡吸附 | S7（可与 S8 并行） | `ui-audit.py` 全绿；两套主题对比度 ≥4.5；截图机判 8 张全过 |
| S10 | **R12 性能**：`LazyForEach` 虚拟化 + Markdown 分段缓存 + 渲染节流 + DB WAL/索引 | S4 | 200 条会话 ≥55fps；单帧 <16ms；冷启动首帧 ≤800ms |
| S11 | **R14 健壮性**：全局异常 + 单一 ticker + 半开连接强制 `destroy` + 重试令牌桶 | S4 | 8 类故障注入用例全过；30 分钟长任务不崩 |

**排序理由**：R0 解决用户当前最痛的问题（慢、不稳），且改动面最小、可独立回滚；R1 从"前置必修"降级为"校准实验"，**不阻塞任何东西**——这正是把 SSE 从主路径摘下来的收益。


---

## 6. 风险与回滚

| 风险 | 影响 | 处置 |
|---|---|---|
| R1 的定位结论可能是"鸿蒙 stream 在特定网络下不推增量" | 逐字流式不可得 | 已有兜底链（SSE→getRun）继续保留；UI 明确标注"快照模式"；不承诺逐字 |
| R2 状态机改写引入新的双终态/漏终态 | 会话卡死 | 状态机单独成模块 + 转移表单测；改造期间保留旧路径开关，可一键回退 |
| R8 拆分把隐性耦合搬错位置 | 编译过但行为变 | S2 只搬不改，禁止在该步顺手修 bug |
| 数据库加列 | 老用户升级失败 | 迁移脚本幂等 + 失败回滚到原 schema；只在启动时执行一次 |
| **`getRun` 自身也可能跨机慢/挂**（R0 的节奏表假设查询廉价） | 整套节奏失效，退化为"转圈" | 连续 2 次 `getRun` 超时即降到 5s 并提示"网络不稳"；**不重试风暴**；保留兜底文案"任务仍在服务端，可重开取回" |
| **ArkTS 的 `setTimeout` 在 async 链里不可靠**（`ChatVM.ets` 注释多处自陈，曾致竞速挂死） | 看门狗不触发或延迟 | 统一用一个 `setInterval` ticker 驱动所有超时判定，禁止嵌套 `setTimeout` 竞速；关键路径加"ticker 未推进"自检 |
| 鸿蒙长时任务（`backgroundTaskManager`）有配额与机型差异 | 后台续跑不稳 | 拿不到租约时不报错，降级为"回前台补一次快照"；**不承诺**后台持续运行 |

回滚粒度：S2 起每步一个 commit，均可单独 revert；数据层改动前先 `hermes-paw.db` 备份到应用沙箱 `backup/` 并保留 2 个版本。

---

## 7. 开源门槛（"可开源"的定义）

1. `tools/arkts-lint.sh` 全绿；`tools/secret-scan.py` 零命中（含 git 历史）。
2. 全部 selftest（s2b / s3 / slash / markdown / s15）在 CI 或本地一条命令跑通，结果入 `docs/test-reports/`。
3. README 含：安全边界（内网≠安全、API 层隔离≠OS 沙箱）、服务器接入步骤、可复制的脚本示例、真机截图。
4. `LICENSE`（建议 MIT）+ `CONTRIBUTING.md` + `CHANGELOG.md`。
5. 仓库不得含证书、UDID、内网地址、任何凭据（含 git 历史，历史污染则重建仓库）。
6. `tools/gpl-guard.py` 零命中：Conduit（GPL-3.0）的私有标识符与注释片段不得出现在 `.ets` 源里（只借语义，不搬代码）。**该守卫只降低风险、不构成法律保证**——结构级改写识别不了，需人工复核（见 §R10 口径限定）。
7. **截图必须可机判**：`tools/shoot-emulator.py` 产出 PNG + 摘要 JSON（关键控件存在性、界面文案断言），不接受"人工看了一眼觉得没问题"。
8. i18n 词条完整性由断言保证：中英 key 集合相等，缺一即失败（对应 §R10-5）。
9. `tools/ui-audit.py` 全绿（对应 §R11）：裸 hex = 0、裸字号 = 0、字号/间距 ⊆ 网格、base 与 dark 键集合相等、两套主题关键组合对比度 ≥4.5。
10. 裸 `hilog.` 调用数 = 0，所有日志经 `LogSafe`（对应 §R13）。
11. `allowBackup=false` 在打包产物中核验；诊断导出样本脚本扫描无 key 片段。
12. **性能基线表** `docs/test-reports/perf-baseline.md`：冷启动首帧、200 条会话滚动帧率、3000 字流式单帧耗时，各 ≥10 次采样给 P50/P95。
13. **故障注入套件**全过（对应 §R14）：断网 / 半开 / 极慢 / DB 损坏 / JSON 截断 / 崩溃重启 / 切网 / 内存压力。

---

## 8. 待裁决（需用户拍板，不自行决定）

| # | 问题 | 推荐 |
|---|---|---|
| D1 | 状态机改造期间是否保留旧路径开关（双实现并存） | 保留 1 个版本，S4 完成后删除 |
| D2 | R1 若证明"鸿蒙 stream 在特定网络下不推增量"且无法绕过，是否接受"快照模式"为正式形态 | **已定为接受**（§R0）；UI 必须明示"实时/快照" |
| D3 | 过程数据归档用 JSON 列还是独立表 | 独立表（便于清理与索引） |
| D4 | 是否引入 i18n（当前文案硬编码中文） | 引入，按 device 跟随 |

---

## 9. 相关文档动作（本文签发后执行）

| 文档 | 动作 |
|---|---|
| `docs/plans/20261026_121047-harmonyos-hermes-client.md` | 整体重写为 v2.5：删掉已被本稿推翻的 BUG-005 结论与"换传输协议"路线，阶段对齐 §5 |
| `docs/test-reports/bug-005-cross-machine-sse-stall.md` | 增补 §1.2 反证与改判，原结论标"已推翻（附实测）"，不删原文以留痕 |
| `README.md` | 补"重构状态"与安全边界节 |
| `docs/server-setup.md` | 核对 gateway 零改动前提下 App 的接入步骤仍完整 |

## 10. 签发记录

| 项 | 内容 |
|---|---|
| 文档 | HermesPaw 重构设计（v1.6 签发版） |
| 评审通道 | 170 · 审爷（`alibaba/deepseek-v4.1-flash`，`openclaw --local`，Gateway 停用期间） |
| 评审轮次 | R1 初评（5 🔴，判不通过）→ R2 窄口径复核（6 条必改，判不通过）→ R3 窄口径复核（2/6 到位，4 条仍差）→ **R4 极窄确认（4 条全到位 + R12/R13/R14 补判，✅ 通过）** |
| 评审结论 | ✅ **签发通过**（2026-11-18） |
| 签发基准 | 送审稿 md5 `11215392ec0474b5d0d9705d2f2afcbf`（= 170 上被审文件的 md5，逐字一致） |
| 复算方式 | 被签发正文 = 文件开头至本「## 10. 签发记录」之前，`rstrip()` 后补回一个换行：`open(f).read().split('## 10. 签发记录')[0].rstrip() + '\n'` → md5 必等于登记值（已用该式实算校验通过） |
| 最终文件 md5 | 不登记（自指悖论：写进去就改变自身），以 **git 提交记录**为准 |
| 本轮闭环 | R2 六条（单次预算/握手判据/验收拆分/预算归一/90s 清除/借鉴章合并）+ R3 四条半改（§0 2.5s、§R1 #2 握手语义、§R1 #3 双份预算、§R3 `canceled`）+ 自查发现的状态机图同源错误 |
| 附：评审方确认项 | R12/R13/R14 均"可实施"；R11 深色 `text_on_accent=#0F1216` 对 -200/-300 级 accent 实测 **5.28–12.12:1**（白字对浅底仅 1.75，确须替换） |
| 遗留 | 无阻断项。§8 的 D1/D3/D4 为待用户裁决的设计选项，不影响实施 |
| 下一步 | **S1 前置**：四格差分矩阵（含跨机 `getRun`）实测 —— 未通过不得进 S1/S2 |

