# 实施状态与实测记录

> 本文件是**实施层**的活文档：记录每一步做了什么、拿什么证据验收、哪些结论被证伪。
> 设计与口径以 `docs/refactor-design.md`（v1.6 签发版）为准，本文不改设计，只记事实。
> 最后更新：2026-11-19 · 基线 commit `6143402`

---

## 1. 步骤状态

| 步 | 内容 | 状态 | 提交 |
|---|---|---|---|
| S1 | R0 双通道：`getRun` 轮询做基线、SSE 只做增强 | ✅ 完成 | `d45337a` |
| S1b | 骨架屏 / 计时器；错误不覆盖正文 | ✅ 完成（错误不覆盖＝结构核实，见 §4） | `d45337a` |
| S2 | R3 放弃条件由 `status` 决定，删两道墙钟 | ✅ 完成 | `1a1e62a` |
| S2fix | 补全 `isKnownActiveStatus`（漏 `queued/claimed/scheduled/stopping/finalizing`） | ✅ 完成 | 并入 `1a1e62a` |
| S3a | R8 拆分第一片：`RunPolicy` 独立模块（纯搬运） | ✅ 完成 | `fbd7e24` |
| S10a | R12 第一片：Markdown 渲染缓存 + 500ms 节流 | ✅ 完成 | `71f0781` |
| S10c | R12 第三片：DB PRAGMA 调优 | ❌ **实测证伪，已回退** | `600a751`（仅记录） |
| S3b | R8 拆分第二片：恢复子系统 → **改为删除**（用户拍板 B，见 §3.6） | ✅ 完成（`ChatVM` 115014 → 94227 B，摘掉 `SIZE_WHITELIST`） | 见 236 `S3b` 提交 |
| S5a | 收口时真正取消 SSE 流（修 finalize 后 idle timeout） | ✅ 完成 | `7142855` |
| S4b | R13 安全闸门：`LogSafe` + 裸 `hilog` = 0 | ✅ **完成 179/179**（6 批：9+16+33+28+20+73）；全仓只剩 `LogSafe.ets` 自身 4 处转发 | `89e2e2a` `f67eda9` `02842d4` `05221fb` |
| S6a | 埋点（不改行为）：`run t0` / 每拍 `poll#N t outLen status` / `first delta` / `finalize total` | ✅ 完成；实测证明 `getRun` 中途 `outLen` 恒 0 | `12ce073` |
| S6b | A：SSE 空闲/读超时 30s → 120s/180s；B：轮询封顶 10s → 5s | ✅ 完成；真机 168.4s 全程 0 次 `stream error` | `fe7b745` |
| S6c | C 等待期三态提示 + D 错误文案补恢复路径 + E 气泡收发时间戳/耗时 | ✅ 完成；真机实测（见 §2.3） | `9381ffc` `b5be999` |

---

## 2. 关键实测（真机 = Mate 80 RS / API 26 / `hdc <内网IP>:<端口>`，实际地址不入库）

### 2.1 短消息收发（同一问题："ping"）

| 时点 | 改动 | 客户端白等到收口 | 证据 |
|---|---|---|---|
| 修复前 | SSE 零帧，降级后一次 `getRun` | **46.91 s** | `docs/test-reports/real-device-baseline.md` §3 |
| S2 | 放弃条件改 status 判定 | 6.10 s（模拟器） | 见 §2.2 |
| S3a | 拆 `RunPolicy`（纯搬运） | 6.32 s（模拟器） | 见 §2.2 |
| S10a | Markdown 缓存 + 节流 | 4.48 s（模拟器） | 见 §2.2 |
| **真机回归** | 上述全部 | **2.02 s** | 见 §2.3 |

> 46.91 s → 2.02 s 的主因不是"让 SSE 变快"，而是**把 SSE 从主路径摘下来**：
> 建 run 即并行轮询 `getRun`，最坏路径从"SSE 一条帧都没有 + idle 30 s"压到"一次 `getRun`"。

### 2.2 模拟器时间线（→ 236 网关）

| 步 | 时间线 | 结果 |
|---|---|---|
| S1 | `14:36:36.159` run created → `baseline poll started 0.001s` → `getRun#1 +2.05s` → `slowed to 4000ms +6.04s` → `finalize completed finalLength=1510 +18.10s` | 18.10 s（模型自身吐 1510 字）；无 `gave up`、无 `unknown status` |
| S2 | `16:01:11.310` run created → `16:01:11.311` poll started 2000ms → `16:01:17.406` finalize `completed` finalLength=491 | 6.10 s；`stream_drop 2300028` 被忽略且 `startRecovery skipped` |
| S3a | `16:20:14.187` run created → `16:20:20.508` finalize `completed` finalLength=748 | 6.32 s |
| S10a | `16:29:52.057` run created → `16:29:56.532` finalize `completed` finalLength=371 | 4.48 s；`ChatVM` 异常日志 0 条 |

**S4b-4 回归（模拟器，5 分 25 秒长任务）** —— 同时也是 §6 待办里「跑一次 5–6 分钟真实 run」的样本：

```
19:06:18.997  run created: id=run_93c2114dd4584027a02136ae3a7cfb1e
19:06:18.997  baseline poll started: interval=2000ms
19:06:25.041  baseline poll slowed down: interval=4000ms
19:06:37.136  baseline poll slowed down: interval=8000ms
19:06:49.010  stream error: kind=stream_drop code=2300028 msg=Operation timeout
19:06:49.010  stream error ignored (baseline poll active)
19:06:49.010  startRecovery skipped: baseline poll is the active channel
19:07:01.195  baseline poll slowed down: interval=10000ms
19:11:43.882  finalize how=completed finalLength=1485
```

- `run created → finalize` = **324.9 s（5 分 25 秒）**，`finalLength=1485`；`gave up` 0、`unknown status` 0。
- 这条证明 **S2 的「只要 `status` 是 active 就不设实际耗时上限」在 5 分钟级长任务上成立**：
  中途 `stream_drop` 一次被忽略（基线轮询才是主通道），随后一路降到 10 s 间隔，直到正常收口。
- 采样注意：模拟器日志的 domain 打成 `A0ff00`（小写），按 `A0FF00` 大写 grep 会得到 0 命中——
  统计脚本必须用大小写不敏感匹配，否则会误判成"没有应用日志"。

### 2.3 真机时间线

```
16:35:37  发送 "ping real" → 回复「pong，在线。2026-11-18 16:35:44 CST」正常上屏
16:44:58.088  run created: id=run_b35eac88337b4924b48fe3cd0fceb82f
16:44:58.088  baseline poll started: interval=2000ms
16:45:00.104  finalize how=completed finalLength=86
```
`gave up` 0 次、`unknown status` 0 次、`jscrash`/`Unhandled` 0 次。

S4b-3 回归（`LogSafe` 已接管 `DbHelper` / `SettingsPage`，34 处调用）：

```
18:05:41.236  session opened
18:05:41.310  run created: id=run_0928264807b14ee7a467be3bcb10f701
18:05:41.310  baseline poll started: interval=2000ms
18:05:47.359  baseline poll slowed down: interval=4000ms
18:05:59.396  baseline poll slowed down: interval=8000ms
18:06:07.435  finalize how=completed finalLength=320
18:06:31.265  stream error: kind=stream_drop code=-2 msg=SSE idle timeout   ← 见下
```

- `run created → finalize` = **26.13 s**，`finalLength=320`。用户当场反馈"回复已输出、并且很快"——
  即**正文是流式先上屏的，`finalize` 只是收口标记**，所以"看得快"与"收口 26 s"并不矛盾。
  本节所有 `finalize` 时间都是**收口时刻**，不是首字时刻，两者不可混用。
- `gave up` 0、`unknown status` 0、崩溃 0。
- ~~**已知待修**：`finalize` 之后 24 s 才报 `SSE idle timeout`~~ ✅ **S5a 已修并实测**。
  根因不是「没调 destroy」，而是 `ApiClient.openStream` 的空闲看门狗活在闭包里
  （`terminated` / `idleTimerId` 外部不可达），`req.destroy()` 停不掉已经 arm 的 JS 定时器，
  30 s 后照旧 `finishError(-2, 'SSE idle timeout')`。修法是 `ApiClient` 登记每个流请求的
  静默取消闭包 + 新增 `cancelStream()`，`RunsApi.cancelEvents()` 透传，`ChatVM.destroyStream()`
  改调它。实测（模拟器，抓 160 s）：`20:02:18.421 run created → 20:02:44.546 finalize
  finalLength=703`（26.1 s），**收口后 135 s 内 `SSE idle timeout` 出现 0 次**（修前是 +24 s 必现）。
- **自动化踩坑（写下来，别再浪费一轮）**：软键盘弹出后输入框会从 `[169,2383][908,2505]`
  跳到 `[169,1570][908,1692]`（上移约 810 px），**盲点按下键盘前的坐标**会落到别处。
  正确姿势：点击输入框 → `sleep` → `dumpLayout` 取**当前** `TextInput` 与"发送"按钮的
  `bounds` 再点。本轮就是因为用了键盘弹出前的坐标，才误判成"`inputText` 没落字"，
  实际上两次 `inputText` 都落进了同一个输入框（后续 dumpLayout 读到
  `s4b3 chec` + `s4b3 ok` 拼在一起），消息是**发出去的**、并且有回复。

S6c（三态提示 + 气泡时间戳）真机实测：

```
11:19:05.754  run created
11:19:11.804  baseline poll slowed down: interval=4000ms
11:19:23.855  baseline poll slowed down: interval=5000ms      ← S6b 的 5s 上限生效，不再到 10000
11:20:39.050  finalize how=completed finalLength=10250 total=93296ms firstDelta=-1ms
```

- 同一条长问题，第 18 秒与第 64 秒两张截图分别读到
  `结果整段生成中 · 已等待 18 秒` / `结果整段生成中 · 已等待 64 秒`，
  助手区仍为骨架屏 —— **与"网关不推增量帧、终态整段上屏"的结论一致**。
- 气泡时间戳实测：`11:19:05 发出`（用户）；短消息样本 `10:56:51 发出` →
  `10:57:01 收 · 用时 10.1 秒`（助手）。
- `gave up` 0、`unknown status` 0、`stream error` 0（168 s 内）。

### 2.4 审批卡实测（2026-11-19 12:01，真机 + 236）

触发命令：`chmod -R 777 /tmp/paw-chmod-probe`（靶目录先建成 `700`，用于判定是否真的执行）。

```
12:01:21.819  236  WARN  Exec approval text prompt send (success=False,
                        error=API server uses HTTP request/response …)
12:01:21.822  236  INFO  Approval prompt handed to gateway notifier
                        (request_id=e289c6303a2f4892a521674eb5c20663)
12:01:28 ~ 12:02:17  App  poll#3…#13  status=waiting_for_approval  outLen=0
12:02:21.823  236  INFO  Approval wait ended (state=timeout, resolved=False, choice=None)
12:02:22 ~ 12:02:32  App  status=running → finalize completed finalLength=694
```

结论三条，全部有物证：

1. **审批门正常触发**：服务端进入审批等待，客户端 13 次轮询都读到 `waiting_for_approval`。
2. **App 没有审批 UI**：发出后 6 秒截图逐字只有 `结果整段生成中 · 已等待 6 秒`，
   没有任何卡片、按钮或倒计时。设计稿里的「审批卡」在代码路径上不可达。
3. **60 秒 fail-closed 生效**：`state=timeout, choice=None`；靶目录权限仍是 `700`
   → **命令没有被执行**（安全侧正确，功能侧等于"永远批不了"）。

根因：网关侧明确报 `API server uses HTTP request/response` —— 文本式审批提示发不出去，
审批只能经 `POST /v1/runs/{id}/approval` 事件式接口交互；App 目前只把
`waiting_for_approval` 当成一个普通 running 态显示，**既没拉审批载荷，也没有提交
approve/deny 的调用**。这是 P0 功能缺口（非文案/样式问题），修复要走代码。

对照：同日 11:49 的 `rm -rf /tmp/paw-approval-probe` 没有触发审批（删 `/tmp` 子目录不在
危险规则内），**且当时模型回复里"命中 always 规则自动放行"是模型自己编的解释**——
236 上既无 `approval.allowed_always` 配置，也无任何持久化记录，`agent.log` 同期无审批事件。
教训：模型对自身机制的解释不可作为证据，必须以服务端日志为准。

### 2.6 开源导出演练（首次，2026-11-19）

`bash tools/opensource-export.sh /tmp/paw-opensource-dry` 全绿：

```
PASS 零内网 IP / 零 token 字面量 / 零内部用户名
PASS hilog 参数位零密钥变量 / 无 >100KB 单文件 / icon 双树字节一致
scanned: 108 text files, 4 binary files (excluded: evidence, docs/test-reports, docs/opensource-research)
OK: 2.7M, 112 files
```

导出边界由 `git archive HEAD` + pathspec 排除，扫描对象是**导出树自身**，所以
「私有 evidence / test-reports 里的 IP 不入包」与「公开树里没有 IP」是两条独立断言。
注意：`secret-scan.py` 仍须另跑（它走 `git ls-files` 全量，与导出边界不同）。

### 2.7 会话标题 / 删除：网关契约核查（供下一步对齐）

**标题两层（`agent/title_generator.py`）**

| 层 | 规则 | source |
|---|---|---|
| 即时派生 `derive_title` | 首条用户消息的首个有意义行，空白折叠，≤48 字符按词边界切 + `…`；不调模型 | `derived` |
| LLM 升级 `generate_title` | aux 模型输出 `{"title":"..."}`，3–7 词；>12 词判为答非所问丢弃；原样回显提示词示例也丢弃 | `llm` |
| 手动 `/title` | `PATCH /api/sessions/{id}` | `user` |

`set_auto_title` 只在标题为空或来源 `derived` 时可写；`_has_upgraded_title` 见到 `user`/`llm` 即跳过升级。
⇒ **App 现在 `POST /api/sessions` 传的自造名（`新对话 <5位>`）非 `derived`，等于把自动命名永久封死**，
这就是服务端列表里一直是占位名的原因。

**删除会话网关已支持**：`DELETE /api/sessions/{session_id}`，`_require_auth` 但未按端点收口；
硬删（行 + transcript 擦洗 + 图片引用回收 + 清渠道路由）；任务在跑返回 409 `session_active_turn`；
不存在返回 404；成功返回 `{"object":"hermes.session.deleted","deleted":bool}`。

**S9a-1 已落地（数据面，2026-11-19）**：新建会话不再传标题（`createSession('')` 不发 `title` 字段）；
本地用与 Hermes `derive_title` 逐字同规则的前 48 字兜底；`syncTitlesFromServer()` 在
`listServerSessions()` 与 `finalizeRun()` 后回写服务端标题；新增 `deleteSession()`（404→false、409 上抛）；
新增纯函数模块 `viewmodel/SessionMerge.ets`（`deriveLocalTitle` / `mergeSessions`，`isLocal` 供 UI 打标签）。

实测（模拟器 + 真机各一轮，`tools/e2e-emu.sh`）：

| 会话 id | 服务端 title | `title_source` | 判定 |
|---|---|---|---|
| `api_1795064386_d85f48c0` | `Confirm end-to-end t…` | **llm** | 真机新会话，自动命名且已升级 |
| `api_1795063786_e94ffcaa` | `e2e ok` | **llm** | 模拟器新会话，同上 |
| `api_1795062070_729b46fb` | `新对话 70384` | *(空)* | 旧包，占位名来源为空 ⇒ 印证根因 |

两轮 E2E 均 `gave up 0 / unknown status 0`，收口分别为 10.1 s（779 字）与 28.2 s（3692 字）。
门禁：新增 `tools/session-merge-selftest.py` **32/32 PASS**（含阴性对照）× 16 个自测全绿；
`arkts-lint` 39 文件 0 findings；`BUILD SUCCESSFUL 3.4 s`；`ChatVM` 99,023 B（闸门 102,400 B）。
编译首轮撞 `arkts-limited-throw`（`throw err` 不能抛宽类型），改 `throw e`（`e: ApiError`）后通过。

### 2.8 S9a-2a 顶部重排 + 面板合并列表（真机已验）

`ChatPage.ets` 1941 → **1963 行 / 76,730 B**（+22 行 / +751 B，仅此一文件，diff 74+/52-）。

- 顶部旧的一排会话 pill（`Scroll` + `ForEach(sessions)`）整段撤掉，改为单行：
  `≡ 会话` + 当前会话标题（占满剩余宽、单行省略）+ `＋ 新对话`。
- 面板列表改 `this.v().mergedSessions()`：每行左侧 10fp 小标签（**本地** 蓝底 / **服务端** 灰底），
  标题单行省略，副行 `N 条 · 相对时间`，服务端行还带 preview；本地行点击走 `onOpenSession(pk)`，
  服务端行走 `onTakeover(id, title)`。
- 新增 `private activeTitle(): string`（按 activePk 匹配本地行取 title，空则「新对话」）。

真机核验（Mate 80 RS）：顶部逐字为 `≡ 会话　新对话　＋ 新对话`，**只有一行、无胶囊**；
面板逐行读到 `本地 / 服务端` 标签与标题、条数、时间，同一 sessionId 未重复出现。

门禁 16 项全绿、`arkts-lint` 39 文件 0 findings、`BUILD SUCCESSFUL 4.5 s`。

**开放项（S9a-2b 一并修）**：面板里最新那条本地会话显示 `本地 · 0 条`，而服务端同会话
`msgs=3`（DB 实查 `hidden=0 arch=0`、按 `last_activity_at` 倒序排第一，`limit=50` 不会截掉）。
即「本地行 `sessionId` 与服务端 `id` 未匹配上」。根因待定：下一步在 `mergedSessions()` /
`syncTitlesFromServer()` 加一行 `LogSafe.d` 打印未匹配的本地 sessionId，一轮即可定位；
同时把 `SessionsApi.listSessions()` 显式带 `?limit=200`（服务端默认 50，本网关已累积 973 条会话）。

### 2.9 S9a-2b 会话长按删除 + 两条数据面修复（真机已验）

三文件：`ChatPage.ets` 1963→**1995 行 / 77,757 B**；`ChatVM.ets` 2394→**2444 行 / 101,634 B**；
`SessionsApi.ets` **162 行 / 6,271 B**。

- **长按删除**：会话行加 `LongPressGesture` → `AlertDialog`（标题「删除会话」、正文带会话名、
  取消 / 删除两键）→ `ChatVM.deleteSession(pk, sid)`：先删服务端（404 视为已删）→ 再删本地行 →
  删的是当前会话则清空并回落；**服务端回 409**（`session_active_turn`）时保留本地行并提示
  「该会话有任务在跑，先停止再删」。`pk` 为空的「仅服务端」行同样可删。
- **limit 修复**：`GET /api/sessions?limit=200`（网关默认 50，本机已累积 973 条会话）。
- **诊断**：`mergedSessions()` 打 `merged: local=N server=M unmatched=K first=<sid>`。

真机实测（Mate 80 RS，删 `新对话 31558` / `api_1795061831_db3ee1af`）：

| 判据 | 实测 |
|---|---|
| 确认弹窗文案 | 逐字「删除会话」/「「新对话 31558」将被删除（服务端会话与本地记录一并删除）。」/ 取消·删除 |
| 服务端删除 | 236 `state.db` 该 id 行数 **0** |
| 本地删除 | 日志 `merged` 的 `local` 由 **18 → 17** |
| **unmatched 归零** | `merged: local=18 server=200 unmatched=0`（修 limit 前是 `server=0/50 unmatched=18`）⇒ 之前「本地·0 条」的根因就是 **默认 limit=50 不够** |
| UI 刷新 | 删除后 4 次重渲染，`dumpLayout` 中已无 `31558` |

编译首轮两错（均本地修）：`arkts-no-structural-typing`（`describeError(e)` 传 `ApiError`
不行，改 `describeError(err as Error)`）、`'vmRef' is possibly 'null'`（`AlertDialog` 的
`action` 闭包里外层空窄化失效，需先取 `let vm2: ChatVM = vmRef;`）。

**风险**：`ChatVM` 101,634 B / 闸门 102,400 B，**只剩 766 B**。下一轮若还要动 ChatVM，
先做一次抽取（把 `mergedSessions()` 里的 unmatched 统计搬进 `SessionMerge` 纯函数，可回收 ~600 B）。

**待决**：无（S9a 全部完成）。

### 2.10 S9c 会话域外移（ChatVM 抽血）+ S9d 列表标题与空会话过滤

**S9c（体量抽血，纯结构性重构，行为不变）**

新建 `viewmodel/session/SessionStore.ets`（**160 行 / 6,104 B**），承载会话域：

| 迁出方法 | 说明 |
|---|---|
| `listLocalSessions()` / `listServerSessions()` | 本地 / 服务端取数 |
| `syncTitlesFromServer()` | 标题对齐 Hermes（`derived` → `llm`） |
| `mergedSessions()` | 合并去重 + `merged:` 诊断 |
| `deleteSession()` | 服务端 404 视为已删 / 409 保留本地行 |
| `takeoverSession()` | 接管已有会话 |

`ChatVM` 只留**同名薄壳**（错误映射 401/`sessionRequired`/`notifyUi` 留在 VM，`SessionStore`
拿不到 UI 与通知）；另把两个纯函数搬进 `SessionMerge.ets`：`unmatchedReport()`、`planTitleSync()`。

| 文件 | 前 | 后 | 变化 |
|---|---|---|---|
| `ChatVM.ets` | 2,444 行 / 101,645 B | **2,395 行 / 98,817 B** | **−2,828 B** |
| `SessionMerge.ets` | 151 行 / 4,644 B | 204 行 / 6,121 B | +1,477 B |
| `session/SessionStore.ets` | — | 160 行 / 6,104 B | 新建 |
| **ChatVM 余量** | **766 B** | **3,583 B** | **+2.8 KB** |

> 回收量比预估（~4.2 KB）少 1.4 KB：薄壳保留的 VM 依赖（错误映射、UI 通知）比预估多。
> 但收益是结构性的——后续会话功能只改 `SessionStore`，不再挤 `ChatVM` 的字节预算。

门禁：`session-merge-selftest` **38/38 PASS**（S9c 新增 J1–J6：两个导出存在性 + Python 复刻
`unmatchedReport`/`planTitleSync` + 2 条阴性对照），全量自测 0 失败、`arkts-lint` **40 文件 0 findings**、
`BUILD SUCCESSFUL 13 s 513 ms`。

**S9d（用户口头要求，只改 `ChatPage.ets`）**

- 面板标题 `$r('app.string.server_sessions_title')`（「服务端会话」）→ 字面量 **`'会话'`**；
  不动三套 `string.json`。
- 新增 `visibleRows(): MergedSession[]`：**本地会话 `messageCount === 0` 无条件不进列表**
  （服务端行仍受「隐藏空会话」开关控制）；空态判断与 `ForEach` 数据源均改为 `visibleRows()`。
  实现放在 `ChatPage` 而非 `mergedSessions()`，避免与 S9c 抢同一段代码。
- `ChatPage.ets` 1996→**2011 行 / 78,260 B**；`arkts-lint` 0 findings、`BUILD SUCCESSFUL 4 s 544 ms`。

**S9d-补（用户口头追加）**：首页顶部中间那格（`activeTitle()` 兜底）从 `'新对话'` 改为 **`'当前会话'`**；
右侧 `＋ 新对话` 按钮与列表行的派生标题不动。`ChatPage.ets` 78,260→**78,269 B**（3 处字面量）。

**真机冒烟（Mate 80 RS，装包 `AppMod finish`，14:23–14:30）**

| 判据 | 实测 |
|---|---|
| 发送路径未回归 | `run created` → `poll#1` → `finalize how=completed finalLength=607 total=28122ms`，错误行 **0** |
| 会话域已由新类驱动 | 日志标签从 `ChatVM` 变为 **`SessionStore`**：`merged: local=22 server=200 unmatched=0` |
| 面板标题 | `dumpLayout` 得 **`会话`**；`服务端会话` 出现次数 **0** |
| 空会话过滤 | 可见 9 行条数为 `[5,8,3,3,3,5,7,5,13]`，**`0 条` 行 0 个** |
| 长按删除（S9c 外移后） | 弹窗逐字「删除会话」「「s9cd smoke」将被删除（服务端会话与本地记录一并删除）。」→ 点删除 → 236 `sessions` 该 id **行数 0**；面板 `s9cd smoke` **不存在** |
| 顶部中间文案 | 顶部单行逐字 `≡ 会话 | 当前会话 | ＋ 新对话` |

> 冒烟过程中踩到两个 `hdc`/`uitest` 坑（已写入技能）：① `uitest uiInput longClick <x> <y>` **没有时长参数**，
> 多传一个数会被当成 `displayId` 而静默失效；② WSL 里调 Windows `hdc file recv` 要在 `/mnt/c` 下执行，
> 且**落地判据要检查 WSL 路径**（`/mnt/c/Users/.../name`），用 `-f 'C:\...'` 永远为假。

**待决**：无。S9c / S9d / 顶部文案均真机已验证。

### 2.11 斜杠命令支持度（真机实测，2026-11-19 14:49–15:10）

App **不转发**斜杠命令给网关（网关 REST 面不分发命令），而是本地拦截 → 翻译成 REST 调用。
完整矩阵与复现方法见 **`docs/slash-command-support.md`**。摘要：

| 类别 | 条数 | 实测 |
|---|---|---|
| App 已映射、可用 | 5（`/new` `/resume` `/title` `/stop` `/approve`） | `/resume` 列表+切换本轮真机走通；`/title` `/stop` 本地拦截（run=0）确认 |
| App 显式拒绝（`当前不支持`） | 7（`/branch` `/save` `/undo` `/retry` `/topic` `/compress` `/sessions`） | `/sessions` `/undo` 实测 run=0 |
| **未映射的 CLI 原生命令 → 当普通消息发给模型** | 其余全部 | `/model` run 1→2、`/help` run 0→1，均产生助手回复（38 s） |

**风险**：`/model` 这类有副作用的命令被当消息发出，用户会误以为已执行。
**决策（2026-11-19，用户拍板）：不做发送前二次确认** —— 现有的「不拦截 `/` 开头的正文」规则保留，
避免误挡用户正常输入；此结论视为终态，不再列为待办。

### 2.12 S10a/S10b 会话空态治理 + 面板搜索（模拟器已验证，真机待复验）

**S10a（数据层）**

- `SessionMerge.ets` 新增 `fallbackTitle(title, sessionId)`：空标题 → `未命名 · <id 后 6 位>`；
  `mergeSessions()` 返回前统一套兜底（204→**219 行 / 6,724 B**）。
- `ChatVM.handleCmdResume` 改吃 `mergedSessions()`（先 `listServerSessions()` 刷新），
  只保留 `messageCount > 0` 的行 → `/resume` 的编号与面板**同源同口径**，不再出现空白行
  （2,395→**2,403 行 / 99,006 B**，余量 3,394 B）。

**S10b（面板 UI，只改 `ChatPage.ets`）**

- 新增 `@State sessionQuery` + 头部下方 `TextInput`（占位「搜索会话」），
  按标题/预览做**不区分大小写子串过滤**；无结果显示「无匹配会话」。
- `visibleRows()` 过滤规则统一：`messageCount === 0 && !hideEmpty` → 本地/服务端**同口径隐藏**；
  「隐藏空会话（N）」开关语义不变（打开后连空会话一起显示）。
- 删除死代码 `visibleServerSessions()`（0 调用点，−19 行）。
- `ChatPage.ets` 2,011→**2,017 行 / 78,507 B**。

**验证（模拟器 + 真机，同一份 HAP）**

| 场景 | 模拟器 | 真机（Mate 80 RS） |
|---|---|---|
| 面板默认 | 8 行可见，`0 条` 行 **0** 个 | 9 行可见，`0 条` 行 **0** 个 |
| 搜索 `e2e` | 8 行 → **4 行**，全部命中 | 9 行 → **4 行**，`Requesting help` 已排除 |
| 搜索 `zzzzz` | **0 行** + 文案「无匹配会话」 | 未测（同代码路径） |
| 打开「显示空会话（4）」 | 9 行，2 行 `0 条`，标题 `未命名 · ce5b7f` / `未命名 · 1dd197` | 开关文案变「显示空会话（4）」，出现 `0 条` 行 + `未命名 · ce5b7f` |
| `/resume` 列表 | — | **10 条，编号连续、无空白行**（首条 `Requesting help` 与面板首行一致 ⇒ 同源生效） |

门禁：`session-merge-selftest` 38→**44/44**（新增 K1–K6：`fallbackTitle` 导出/套用/三种取值 + 2 条阴性对照）；
全量自测 0 失败；`arkts-lint` 40 文件 0 findings；`BUILD SUCCESSFUL 4 s 365 ms`。

**真机提示**：无线调试在灭屏后会掉线（`E001005 Device not found`），解锁屏幕即可恢复；
跑真机脚本前先 `tconn <ip>:<port>` 并确认 `shell echo` 有回显。

**待决**：无。

### 2.14 双语文档索引 + RS 80 真机回归（S11 收尾）

**文档**：新增 `docs/README.md`（中文索引）与 `docs/README.en.md`（英文索引），11 篇文档按
「回答什么问题 / 给谁看 / 是否仍可作为依据」列表，带状态标记（📌 设计基线、🔄 活文档、✅ 现行、
⏸️ 休眠、🗄️ 历史）。两页互链，主 README 中英两版都给出双入口。正文不复述内容、只给判断依据，
避免"读了过时记录当现状"。

**真机回归（Mate 80 RS / API 26，无线调试）**：

| 检查项 | 结果 |
|---|---|
| 界面中文完整性 | `≡ 会话 / 当前会话 / ＋ 新对话 / 发送 / 对话 / 设置 / 关于`，逐字正确 |
| 裸 key 泄漏 | **0**（`m_` 前缀 key 一个都没出现在界面上） |
| 会话面板 | 标题 `会话`、`隐藏空会话（5）`、`刷新`、`服务端` 标签、真实会话行 `github仓库日报 · Nov 20 09:30 / 2 条 · 11-20 09:30` |
| 运行时文案（走 Msg.t 资源） | `未选择图片`、`结果整段生成中 · 已等待 N 秒`、`审批超时：已自动拒绝` 三条均正常渲染 |
| 气泡时间戳 | `10:26:44 收 · 用时 639.3 秒`（i18n 后 `收` / `用时` 片段仍正确拼接） |
| 发送链路 | `run created` → `poll#1..80` 连续轮询 393 s 无放弃、无错误行（0），最终 `用时 639.3 秒` 收口 |
| 长回答归因 | 服务端该会话 `output_tokens=19611 / message_count=65`——模型自身吐字耗时，**不是 App 卡住**；客户端按设计不设实际耗时上限 |

**新增踩坑**：真机 `uitest dumpLayout` 在软键盘弹起时**只返回键盘窗口**，对话区与顶部栏全丢；
此时按文本定位「发送」按钮得到 `0,0`。稳妥做法是先点消息区收键盘再 dump，或用截图 + 视觉核验。
另有两次误操作：为找输入框点了 `📷` 图标打开相册选择器；按 `Back` 键把 App 退到桌面——
脚本里不要用 `Back` 收键盘，改为点空白区。

### 2.13 S11 运行时文案 i18n 收口（双语完整）

**问题**：163 个 UI 资源 key 三语齐全，但 **206 处运行时文案硬编码中文**（ChatVM 77、ChatPage 33、
ScanVM 18、SettingsVM 14、ErrorText 13…），英文模式下错误/提示/状态条仍是中文。

**做法**：新增 `utils/Msg.ets`（`Msg.init(ctx.resourceManager)` + `Msg.t('key')`），
文案全部进 `resources/{base,zh_CN,en_US}/element/string.json`——与声明式 UI 的 `$r()` **共用同一套表**，
不引入第二套翻译源。入口 `EntryAbility.onCreate` 注入 resourceManager；未初始化时 `Msg.t` 回退返回 key（可见即缺陷）。

| 项 | 结果 |
|---|---|
| 资源 key | 163 → **345**（base / zh_CN / en_US 三套一致） |
| 改写调用点 | **206 处 / 16 文件**（词法扫描替换：只动代码区完整字符串 token，不碰注释） |
| 代码区剩余硬编码中文 | **0** |
| 新增闸门 | `tools/i18n-selftest.py` 5 项：三语 key 一致 / en_US 无中文 / 代码区零硬编码 / `Msg.t` key 均已定义 |
| 编译 | `BUILD SUCCESSFUL 7s117ms`，0 ArkTS 错误 |
| 门禁 | 17 组自测 0 失败（含新 i18n 组）；`arkts-lint` 41 文件 0 findings |

**真机（模拟器 API 26）实测英文模式**：
顶部 `≡ Sessions / Current session / + New chat / Send / Chat·Settings·About`；
发 `/undo` → 气泡 **“Not supported here: /undo”**（原为「当前不支持 /undo」）。

**刻意例外**：`util/OnboardPrompt.ets`（首次接入提示词）**保持中文**——它是发给网关 agent 的指令模板，
必须与 `tools/hermes-paw-qr --prompt` 字节一致（由 `s15-selftest` 守护）。已写入 i18n 闸门白名单。

**踩坑**：① ArkTS 资源名**不允许点号**（只允许 `[a-zA-Z0-9_]`），首版 `photo.empty` 直接打包失败；
② 去点号后与既有 163 个 key 撞名（`scan_no_gateway`），统一加 `m_` 前缀区分；
③ 用正则直接替换字符串会被**注释里的引号配对**误伤（生成 `err__token`、改坏一行注释），
改用词法状态机（区分 code / 字符串 / 行注释 / 块注释）后才干净。

### 2.5 审批卡修复与闭环验证（2026-11-19 12:17，真机）

修复前：服务端会进 `waiting_for_approval` 并 60s fail-closed，但 App 从不渲染卡。
两次误判与真因（都留在记录里，避免再猜）：

| 轮次 | 假设 | 实测结果 |
|---|---|---|
| S8a | GET 返回顶层 `approval` 字段 | ❌ 该分支的埋点日志从未出现 |
| **S8b** | GET 走 `run_projection()`，审批在 **`pending_controls[]`**；`Run.ets` 解析对，但 **ChatVM 从未读它** | ✅ 日志出现 `approval card from snapshot: promptId=… choices=4` |

修复：`ChatVM.baselinePollOnce` 里 `status=waiting_for_approval && pendingApproval===null` 时取
`pending_controls[0]`（无则退回 `approval`），调既有 `setPendingApproval()`。UI 未改一行
（卡片与四选项本来就有）。

真机闭环（靶目录先建为 700）：

```
12:17:52.490  run created
12:18:02.556  poll#3 status=waiting_for_approval
12:18:02.556  approval card from snapshot: promptId=d4ef…(32) choices=4
              ← 人工在卡片上点「本次批准」
12:18:06.822  poll#4 status=running
12:18:15.604  poll#6 status=completed outLen=361
12:18:15.606  finalize completed finalLength=361 total=23116ms
```

- 服务端物证：`/tmp/paw-approve-probe` **700 → 777**（drwxrwxrwx）。
- 助手回复原文：`chmod -R 777 … exited 0 … now drwxrwxrwx`。
- 结论：**审批卡「批准」路径已真机走通**。

「拒绝」路径（同日 12:21，靶目录 `/tmp/paw-deny-probe` 建为 700）：

```
12:21:16.504  poll#2 status=waiting_for_approval
12:21:16.505  approval card from snapshot: promptId=401a… choices=4
              ← 人工在卡片上点「拒绝」
12:21:18,355  236 tools.approval: Approval wait ended (state=set, resolved=True, choice=deny)
12:21:18,389  POST /v1/runs/{id}/…  200 583        ← 决策确实提交到了服务端
12:21:20.522  poll#3 status=running               ← 不是执行命令，是模型继续对话
12:21:24.532  poll#4 status=completed outLen=325
```

- 服务端判定：`choice=deny`、`resolved=True`，命令**未执行**；靶目录保持 **700**。
- 助手回复（App 内原文）："命令被你拒绝了，未执行，所以没有产生真实的退出码（系统标记为
  blocked / exit=-1）。不做重试。"
- **两条路径都通**：批准 → chmod 执行（700→777，exit 0）；拒绝 → 拦下（保持 700，无退出码）。

**安装脚本三个坑（同一个下午连踩三次，写下来）**：

1. `hdc install -r` 在 Windows 上**只认反斜杠绝对路径**。传 WSL 的 `/mnt/c/...` 会被拼成
   `C:\...\hermes-paw\/mnt/c/...`；传 `C:/Users/...`（正斜杠）会被当成相对路径、前面再拼一次 cwd。
   两种都报 `no such file or directory`。正确写法见 `tools/e2e-emu.sh` 的 `HAP=` 默认值。
2. **安装失败必须中止**。脚本不断言安装结果时，后面整轮跑的都是旧包，日志却"看起来正常"
   （轮询间隔、finalize 都有），极易被当成新包的证据 —— 这就是本轮差点把 11:02 的包当成
   11:19 的实测。
3. `hdc install` 成功时**末行是 `AppMod finish`，不含 `success` 字样**。断言要按
   `AppMod finish` / `success` 两种成功形态写，失败形态是 `[F]` / `error` / `Device not found`。


---

## 3. 被证伪 / 被撤回的结论（写下来是为了不再犯）

### 3.1 DB PRAGMA 调优无效（S10c，已回退）

`executeSql('PRAGMA journal_mode=WAL / synchronous=NORMAL / busy_timeout=5000')` 在 HarmonyOS
`RdbStore` 上**不报错也不生效**。真机读回：

```
db pragma: journal_mode=unknown sync=2 busy=2000
```

请求 `synchronous=NORMAL(1)` 读回 `2`(FULL)；请求 `busy_timeout=5000` 读回 `2000`(框架默认)。
`-wal` 文件确实存在，但不能归因于本次改动。**代码已原样回退**，详见
`docs/test-reports/db-pragma-finding.md`。

**教训**：把"PRAGMA 语句存在"当验收（静态断言 11/11 全绿）是**假验收**；真验收是"读回值 =
NORMAL / 5000"。静态断言只能证明代码写了什么，不证明系统变成什么样。

### 3.2 `auth probe: 404 → legacy gateway` 不是缺陷（撤回）

一度被判为"可能误认网关无鉴权"，重读代码后确认是 P2 决议表的既定路径：该网关没有
`/api/auth`，没有会话可掉。**不修**。

### 3.3 `§R3` 未枚举 active 状态成员是设计缺口

S2 落地时发现 `isKnownActiveStatus` 只认 3 个状态，而网关实际会返回
`queued`（`api_server_runs.py:857/910` 的初始状态）、`claimed`（`:1043`）、`stopping`
（`:273/:1109`）、`scheduled`、`finalizing`。漏一个 → 该状态的 run 连续 3 拍（≈6 s）被判
`protocol-error` 提前收口。已在代码补全并加断言，但**设计文档 §R3 仍只写"active 就一直等"**，
照文档实现的人会重现同一个 bug。改签发文档需重走评审，故此处登记为**已知缺口**。

### 3.4 S3b 两次未产出（不是代码写错，是轮次没落地）

- 第 1 次（S3b-a）：码爷把 19 文件 86 处一次做，写 `LogSafe.ets` 时撞输出 token 上限
  （`stopReason=length`），`out/` 只有一个未改的 `README.md`。
- 第 2 次（S3b，范围已收到 5 文件）：码爷工具在运行中被吊销（`stopReason=stop`），
  自述"工具恢复后可以在一个回合内落地，本轮到此为止，不冒充完成"，`out/` 为空、
  `work/` 无产物。

两次都没有污染仓库（`git status` 干净），但 `ChatVM.ets` 仍 115527 B、仍靠
`SIZE_WHITELIST` 放行。**结论：拆分这类跨方法搬家的活，要在单轮内能完整产出的粒度下派**，
下次切到"先只搬 4 个方法"。

### 3.5 `arkts-lint` 全绿 ≠ 能编译（S4b-3 交付真实翻车）

S4b-3 交付版把 34 处调用写成 `LogSafe.debug/info/warn`，而 `LogSafe.ets` 只有
`d/i/w/e` 四个方法——`arkts-lint` 是自定义规则集、不做类型解析，所以 37 文件 0 findings
照样"全绿"；`logsafe-selftest` 前 9 条只数 `hilog` 计数，也发现不了。

处置：本地机械改名 34 处（`debug→d`、`info→i`、`warn→w`），并给门禁加了两条：
- **#10** 全仓 `LogSafe.X` 的 `X` 必须在 `LogSafe.ets` 里声明过；
- **#11** 反向对照：把一处 `LogSafe.d(` 改成 `LogSafe.debug(`，#10 必须变红。

教训写在这里：**计数类门禁只能证明"迁移做全了"，不能证明"迁移做对了"**；
对"新引入的符号"必须有一条存在性校验，否则编译才知道错。

### 3.6 观察：恢复子系统（recovery）在当前架构下几乎不会被执行（待决策）

每次实测都能看到 `startRecovery` 的第一条守卫直接返回：

```
19:06:49.010  stream error ignored (baseline poll active): kind=stream_drop code=2300028
19:06:49.010  startRecovery skipped: baseline poll is the active channel
19:39:14.597  stream error ignored (baseline poll active): kind=stream_drop 2300028
20:02:44.546  同一形态（无 recovery 相关日志）
```

原因在 S1 的主从反转：`getRun` 基线轮询在 `sendMessage` 时就启动并贯穿整个 run，
所以 `startRecovery()` 首行 `if (this.baselinePollTimer !== -1) return;` 永远命中；
`recoverTick` / `recoverTickInner`（约 250 行、约 17.8 KB）成为**事实上的不可达路径**。

这直接影响 S3b 的取舍，三个选项（**用户已拍板：B 删除**）：

| 选项 | 收益 | 风险 |
|---|---|---|
| A. 拆到 `stream/RecoveryController.ets`（原计划） | `ChatVM` 115.7 KB → 约 98.3 KB，可摘 `SIZE_WHITELIST`；保留未来复用 | 拆分本身是跨 20 个宿主成员的搬家，历史两次派单都没落地 |
| B. 直接删除恢复段 ✅ **已执行** | `ChatVM` 115014 → **94227 B**，删掉 250 行不可达代码、5 个 `recover*` 字段、9 个 `RECOVER_*` 常量与配置页 getter/setter | 删掉"SSE 还能救"的兜底；若哪天把基线轮询关掉，就没有恢复通道了 |
| C. 保留不动，`SIZE_WHITELIST` 维持豁免 | 零风险 | 100 KB 闸门对 `ChatVM` 形同失效，后续只会更大 |

删除后的实测（真机 RS 80，5 分 36 秒长任务）：
```
08:53:47.091  run created
08:54:17.103  stream error: kind=stream_drop code=2300028 msg=Operation timeout
08:54:17.103  stream error ignored (baseline poll active)
08:54:17.103  openEvents failed: baseline poll remains the only channel   ← S3b 新日志
08:54:29.260  baseline poll slowed down: interval=10000ms
08:59:23.533  finalize how=completed finalLength=2323
```
SSE 在建 run 后 30 秒就死了，基线轮询照样在 5 分 36 秒后取回 2323 字全文并收口，
`gave up` 0、`unknown status` 0、收口后无 `SSE idle timeout`。**删除没有破坏取数路径。**

---

## 4. 结论分级（哪些是实测，哪些只是核实）

| 结论 | 证据等级 |
|---|---|
| 46.91 s → 2.02 s | **真机实测**（hilog 时间线） |
| SSE 跨机可用、BUG-005 服务端结论不成立 | **实测**（首字节 0.07 s、35 s 收 3039 B、`seq` 连续） |
| 放弃条件改 status 后长任务不被掐 | 模拟器实测（短任务）；长任务未跑 5–6 分钟样本 |
| 错误不覆盖已有正文 | **结构核实**（`finalizeRun` 先算 `finalText` 再清 `streamText`；`messages` 只在新建/切换会话清空；错误走独立顶部条）——**未做故障注入** |
| Markdown O(n²) 已消除 | 静态断言 14/14 + 行为复刻 4 用例；**未在真机采样帧率** |
| DB PRAGMA 无效 | **真机实测**（读回值） |
| 系统备份不含应用数据 | **官方文档 + 代码核对**（`module.json5` 无 backup 扩展，`allowToBackupRestore` 默认 false） |

---

## 5. 体量与门禁现状

| 文件 | 行 | 字节 | 说明 |
|---|---|---|---|
| `viewmodel/ChatVM.ets` | 2395 | 98817 | **余量 3,583 B**（上限 102400）；S9c 会话域外移后 |
| `viewmodel/session/SessionStore.ets` | 160 | 6104 | S9c 新建：会话域（取数/合并/同步/删除/接管） |
| `viewmodel/SessionMerge.ets` | 204 | 6121 | S9a-1 建立；S9c 加 `unmatchedReport` / `planTitleSync` |
| `pages/ChatPage.ets` | 2011 | 78260 | S9d 加 `visibleRows()` + 面板标题「会话」 |
| `net/SessionsApi.ets` | 162 | 6271 | `?limit=200`；`deleteSession` 404/409 语义 |
| `model/ChatMessage.ets` | 155 | 5817 | S6c 加 `elapsedMs` / `firstDeltaMs` |
| `viewmodel/stream/RunPolicy.ets` | 70 | 3831 | S3a 产物 |
| `viewmodel/stream/PollPolicy.ets` | 23 | 891 | S7a 产物 |
| `utils/MdCache.ets` | 119 | 4642 | S10a 产物 |
| `utils/LogSafe.ets` | 90 | 约 3000 | S4b-0 产物，全仓唯一 `hilog` 出口 |

`SIZE_WHITELIST` 现只有 `{'hvigorw.js'}`；HAP 单测基线 **71 passed / 0 failed**（`hap-unit-test.ps1` v4，
日志 `hap-unit-test.log`，旧记录 68 是 hvigor 缓存复用造成的假象）。

门禁 **16 项** + lint（`arkts-lint` **40 文件 0 findings**）：

```
secret-scan  s3-selftest  s2-selftest  s2b-selftest  s2c-selftest  setup-uri-selftest
markdown-selftest  slash-selftest  s15-selftest  s10-selftest  logsafe-mask-selftest
logsafe-selftest（11 条断言，含 3 条反向对照：注入裸 hilog / 偷迁一处 / 调未声明成员）
sse-cancel-selftest（7 条断言 + 1 条反向对照，S5a 产物）
poll-policy-selftest（18 条断言，S7a 产物）
session-merge-selftest（38 条断言，S9a-1 建立 / S9c 扩到 J1–J6，含 2 条阴性对照）
arkts-lint
```

### 5.1 与签发设计文档的偏离（如实记录，不改设计正文）

| 设计条款 | 设计原文 | 实际做法 | 状态 |
|---|---|---|---|
| §R8 拆分 | 把恢复子系统搬到 `stream/RecoveryController.ets`，宿主接口 11 读 + 6 写 + 4 动作 | **整块删除**（S1 之后 `startRecovery()` 首行即被基线轮询挡住，整段不可达） | 用户已拍板 B 方案；设计正文未改，**待重走评审** |
| §R3 active 状态表 | 需列出网关全部 active 成员 | 代码已覆盖 8 态（`RunPolicy.isKnownActiveStatus`），文档表格未补 | 未做，需评审 |

> 本文只记事实，不擅自改签发文档。R8 的表述冲突留待评审时一并处理。

---

## 6. 待办（2026-11-19 重写，旧版已全部完成）

### 6.1 已完成、旧版待办作废

- ~~S3b 抽 `RecoveryController`~~ → **改为删除并完成**（`ChatVM` 97157 B，白名单只剩 `hvigorw.js`）
- ~~S4b 裸 `hilog` 归零~~ → **179/179 完成**
- ~~长任务样本~~ → 已有 324.9 s / 336.4 s / 168.4 s / 93.3 s 四个样本

### 6.2 剩余

| # | 项 | 类型 | 说明 |
|---|---|---|---|
| 1 | §R8 / §R3 与实现不一致 | 文档 | 见 §5.1；改签发文档需重走评审，待用户定"重签"还是"仅记偏离" |
| 2 | ~~审批卡 60 秒窗口真机点击~~ | ✅ **已闭合**（S8a+S8b，真机走通「批准」路径） | 见 §2.4 与 §2.5：卡渲染 → 点批准 → 服务端执行 777 → 结果回 App |
| 3 | `ChatVM` 余量 5.2 KB | 技术债 | 97157/102400；要么小额拆分（抽轮询/埋点），要么正式调阈值并写理由 |
| 4 | `tools/e2e-emu.sh` 缺安装断言 | 工具 | 今天"测了旧包还以为通过"的根因；断言目前只在 `/tmp` 临时脚本里 |
| 5 | `tools/opensource-export.sh` 未演练 | 开源前置 | `secret-scan` 只扫当前树，不扫导出物；开源前需跑一次并复核导出包 |
| 6 | 大文件 UI 改动走不走管道 | 流程 | `ChatPage.ets`（1941 行）让 170 连续超时两次；是否改为本地改 + 门禁，待用户拍板 |

---

## 7. 相关文档索引

- 设计（签发版）：`docs/refactor-design.md`（正文 md5 `11215392ec0474b5d0d9705d2f2afcbf`）
- 真机/模拟器基线：`docs/test-reports/real-device-baseline.md`
- SSE 四格差分矩阵：`docs/test-reports/sse-capability-matrix.md`
- 每步改动说明：`docs/test-reports/change-S2.md`、`change-S2fix.md`、`change-S3a.md`、`change-S10a.md`
- 证伪记录：`docs/test-reports/db-pragma-finding.md`
- 斜杠命令支持度矩阵：`docs/slash-command-support.md`（真机实测 14 条 + 未映射风险）
