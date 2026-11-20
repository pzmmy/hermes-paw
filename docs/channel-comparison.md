# HermesPaw 与官方 IM 通道（企微 / 个人微信）的能力对比

> 结论先行：**不是替代关系，是分工**。
> 手机随时在线、轻量对话、要推送 → 用企微/微信通道；
> 人在同一局域网、要审批/停止/插话/翻历史 → 用 HermesPaw。
>
> 本文的每一条判断都对应网关源码里的位置，便于复核；随 Hermes 版本演进可能变化，最后核对于 Hermes 0.23.x。

## 一、先讲清两者的结构差异

| | 官方 IM 通道 | HermesPaw |
|---|---|---|
| 链路 | 手机 → **IM 服务商服务器** → 本机网关插件 → agent | 手机 → **局域网直连** 网关 `api_server`（`/v1/*`） |
| 身份 | IM 账号（企微成员 / 微信好友） | 网关 profile + 长效 Bearer key（扫码写入） |
| 消息形态 | 文本 + 有限富文本，受平台限速/长度约束 | 结构化：`run` 快照、`pending_controls`、SSE 事件 |
| 谁能看到内容 | 网关 + **IM 服务商** | 仅内网链路两端 |

一句话：IM 通道是「把 agent 塞进聊天软件」，HermesPaw 是「给 agent 做原生遥控器」。前者覆盖面广，后者操作面深。

## 二、逐项对比

| 维度 | 企微通道（`plugins/platforms/wecom`） | 个人微信（`plugins/platforms/weixin`） | HermesPaw |
|---|---|---|---|
| **安装成本** | 零安装（手机本就有企微，扫码入应用） | 零安装（扫码登录，需保持进程在线） | 需装 HAP（DevEco 构建或分发），需扫码接入 |
| **网络要求** | 有公网即可，跨网段/跨地域可用 | 同左 | **仅同一局域网**（不做公网中继） |
| **到达方式** | 企微推送 + 系统通知，App 不在前台也收得到 | 微信推送 + 系统通知 | **无推送**：前台轮询；退到后台靠系统调度，及时性差 |
| **执行审批（危险操作确认）** | **纯文本兜底**：审批提示以文本下发，用户回 `/approve`；网关默认窗口 **300 s**，超时**默认拒绝** | **未见执行审批接线**（插件里只有 DM 配对审批），危险操作基本无法在微信里确认 | **审批卡片**：四个选项（本次 / 本会话 / 固定 / 拒绝）+ **60 s** 倒计时，到点 fail-closed；真机三条路径实测过 |
| **停止任务** | 文本命令 `/stop` 在网关命令层可识别（`gateway/run_busy.py` 按「停当前 chat 的活」处理） | 同上（取决于插件是否转发命令） | 顶部「停止」按钮，立即回显 `已停止` |
| **中途纠偏（steer）** | 未接 | 未接 | 输入框直接发即为插话，回显 `已插入 / 插话未被接受` |
| **run 生命周期可见性** | 只有聊天文本，看不到「排队/运行/等审批/收尾」状态 | 同左 | 三态状态条 + 每次轮询的 `status`、`outLen`、耗时 |
| **长输出** | 企微有 **30 条/分钟** 限速，长文按 `MAX_MESSAGE_LENGTH` 分片 | 微信长文折叠/分段，阅读体验依赖客户端 | 一次性完整渲染，气泡带 `HH:MM:SS 发 / 收 · 用时 X.X 秒` |
| **历史会话** | 散在 IM 聊天记录里，无标题同步、无搜索、无删除 | 同左 | 合并本地 + 服务端会话列表（`?limit=200`）、标题由服务端 `llm` 生成并回同步、支持搜索与长按删除 |
| **多网关（家用/公司）** | 一个通道 = 一个机器人，多套要各自配 | 同左 | 多 profile 扫码并存，顶部显示当前连的是哪台（`已连接：<名称>`） |
| **内容外泄面** | 对话内容经企微服务器落盘留痕 | 经微信服务器 + 第三方插件进程 | 仅内网 HTTP，凭 Bearer key 鉴权（仍建议网关侧限源） |
| **断网/离线** | 断开后消息排队，恢复后补发 | 同左 | 断流按 2/4/8/16/30 s 指数退避重连；失败 3 次明确报 `连接中断` 并给动作 |

## 三、为什么 HermesPaw 的审批必须做成"卡片 + 60 秒"

IM 通道的 `/approve` 文本确认有两个固有弱点：

1. **看不出"现在在等什么"**——聊天窗口里，一条审批提示很容易被后续消息淹没，用户不知道自己正卡在一个待决动作上；
2. **窗口太长**——网关默认 300 s，对一条 `rm -rf` 或 `chmod -R 777` 来说，五分钟里发生别的事太容易，容易"顺手批了"。

所以客户端的取舍是：**把审批做成一次显式的、有倒计时的、默认拒绝的交互**。三条路径（批准 / 拒绝 / 超时）都在真机上验过：批准后靶目录 700→777 且 exit 0；拒绝后保持 700；超时不点则自动拒绝、靶目录保持 700。

这也解释了为什么它不适合做成"公网可用"：审批是要人在现场、在几十秒内做决定的动作，把这条链路暴露到公网反而放大风险。

## 四、什么时候用哪个

| 场景 | 建议 |
|---|---|
| 在办公室/家里，但人不在电脑前（换房间、开会、沙发） | **HermesPaw**：看进度、批危险操作、插话纠偏 |
| 出差、通勤、在客户现场，只看结果、只发指令 | **企微 / 微信通道**：能收推送，不需要看 run 状态 |
| 让 agent 跑长任务，想被"叫醒" | 用 IM 通道收通知；需要深操作时再回到局域网用 App |
| 需要事后翻历史、比对某次 run 花了多久 | **HermesPaw**：会话列表 + 时间戳/用时是逐条留存的 |

## 五、给英文读者的摘要（供 dev.to 使用）

> HermesPaw is not a replacement for the messenger channels that Hermes ships with. Those are great
> when you are off-network: they push, they need no install, they work from anywhere.
> What they cannot do is give you the *run* — the lifecycle, the approval decision, the steering.
>
> In the gateway source, interactive exec approval (`ExecApprovalPrompt`) is implemented for
> Discord, Feishu, Matrix, QQ, Slack, Teams, Telegram and WhatsApp Cloud — **not** for WeCom or
> WeChat. Those channels fall back to a plain-text prompt plus `/approve`, with the gateway's default
> approval window of 300 seconds. HermesPaw instead reads `pending_controls` from
> `GET /v1/runs/{id}` and renders a four-choice card with a 60-second fail-closed countdown.
>
> The trade-off is deliberate: the app only speaks to the gateway on the same LAN, because an
> approval is a decision a human should make on the spot, not one to expose to the public internet.

## 六、复核入口（源码位置）

| 事实 | 位置 |
|---|---|
| 交互式审批的实现清单 | `plugins/platforms/*/adapter.py` 中引用 `ExecApprovalPrompt` 的适配器（discord/feishu/matrix/qqbot/slack/teams/telegram/whatsapp_cloud） |
| 文本兜底 + 默认 300 s 窗口 | `gateway/platforms/base_exec_approval.py`（`approval_timeout_seconds()` 默认 300；文案 `gateway.exec_approval.deadline`） |
| 企微审批走控制通道 + 30 条/分钟 | `plugins/platforms/wecom/adapter.py`：`send(..., metadata["is_approval_prompt"])` → `is_control`；注释标注 30 msgs/min（issue 846607） |
| `/stop` 的语义 | `gateway/run_busy.py`（停在当前 chat 的活）；`gateway/platforms/api_server_runs.py` 的 REST 命令映射 |
| App 侧审批渲染 | `entry/src/main/ets/viewmodel/ChatVM.ets`（消费 `pending_controls[0]`）+ `pages/ChatPage.ets`（卡片与 60 s 倒计时） |
