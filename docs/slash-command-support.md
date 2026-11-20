# App 对 Hermes CLI 斜杠命令的支持度（真机实测矩阵）

> 实测环境：Mate 80 RS / API 26，App = `com.pzmmy.hermespaw` @ `d449f57` + `/resume` 测试轮；
> 网关 = 内网「守门人」节点（Hermes v0.23.0）。
> 实测判据：发出后 6 秒内 App 日志是否出现 `run created`（出现 = 走到模型；不出现 = 本地拦截）。

## 0. 结论先说

**App 不转发斜杠命令给网关，它自己拦截并翻译成 REST 调用。**这不是缺陷，是网关架构决定的：

- 网关的原生命令集只对**走消息管道**的 surface（CLI / 企微 / Telegram）生效；
- App 走的是 REST 面（`POST /api/sessions/{id}/chat` → `_run_agent`），**不经过命令分发器**；
- 所以如果 App 不拦截，`/xxx` 会**当成普通消息发给模型**。

实测中模型自己把这件事说清楚了（`/model` 的回复原文）：

> 「/model 是 CLI/TUI 交互会话里的斜杠命令，在 API 通道里直接打 /model 会当成普通消息发给我。」

## 1. 已映射并可用（5 条，App 表 `net/SlashCommands.ets`）

| 命令 | App 行为 | 映射端点 | 实测 |
|---|---|---|---|
| `/new` | 新建会话，气泡「已新建对话」；busy 时提示「请等当前任务完成后再切换」 | `POST /api/sessions` | ✅ 可用（S9a-1 轮验证；本轮代码路径复核） |
| `/resume` | 无参 → 气泡列出前 10 条（编号+标题）；带参 → 按序号或标题关键词切会话 | `GET /api/sessions` + 会话接管 | ✅ **本轮真机验证**：`/resume` 出列表、`/resume 3` 切到 `Confirm end-to-end testing ok` 并加载历史 |
| `/title` | 无参 → 显示当前标题；带参 → `PATCH` 改名 + 本地行同步 | `PATCH /api/sessions/{id}` | ✅ 本地拦截确认（run=0）；改名路径复用 S9a-1 已验证的 `setTitle` |
| `/stop` | 复用 `stopStream()`（`stopRequested` + `destroy` + `POST /stop` + 收口） | `POST /v1/runs/{id}/stop` | ✅ 本地拦截确认（run=0）；有在跑任务时的停止路径 S5a/S6b 已验证 |
| `/approve` | 走审批卡同一套 `POST /approval` | `POST /v1/runs/{id}/approval` | ✅ 批准/拒绝/超时三路 S8b 已真机验证（走卡片，非命令） |

## 2. 显式拒绝（7 条，`KNOWN_UNMAPPED`）

`/branch` `/save` `/undo` `/retry` `/topic` `/compress` `/sessions`

App 行为：弹系统气泡「当前不支持 /xxx」，**不发模型**（代码事实：`handleSlashCommand` 命中 `isKnownUnmapped` 即 `return true`）。

理由：这些命令在网关侧**没有等价 REST 端点**，硬做只能靠改 gateway（本项目红线：不改网关）。

实测：`/sessions`、`/undo` 本轮实测均 run=0（未进模型），与代码一致。

## 3. 未映射的 CLI 原生命令 → **当普通消息发给模型**（风险项）

本轮实测：

| 命令 | 结果 | 证据 |
|---|---|---|
| `/model` | **进模型**（App 把它当消息发了） | 日志 `run created` 1→2；界面出现用户气泡 `/model 14:54:17 发出` + 助手 38 秒长回复 |
| `/help` | **进模型** | `run created` 0→1；助手回复「你好，我是 Hermes Agent（236 守门人）…常用斜杠命令…」用时 38.1 秒 |

同类未映射（行为相同，未逐条实测）：`/status` `/tools` `/usage` `/memory` `/cron` `/config` `/model` `/personality` `/reasoning` `/verbose` `/yolo` `/agents` `/history` `/insights` `/platforms` `/quit` `/bg` `/queue` `/steer` `/reset` `/restart` `/compact` `/clear` 等全部 CLI/TUI 命令。

**风险**：用户在 App 里敲 `/model` 期望切模型，实际是"让模型解释怎么切模型"，**看起来像执行了，其实没执行**。`/help` 这种无害，`/model` `/yolo` `/cron` 这种有实际副作用的会误导。

## 4. 待办建议（按性价比）

| 优先级 | 项 | 说明 |
|---|---|---|
| ~~P2~~ | ~~未知 `/xxx` 的**发送前确认**~~ | **不做（用户 2026-11-19 拍板）**。理由：现规则「永不拦截 `/` 开头的正文」是刻意的，加确认会误挡正常输入；风险已知并接受 |
| P3 | 映射表补 `/status` 之类只读命令 | 需要网关有等价端点；目前 `GET /v1/runs/{id}`、`GET /api/sessions` 够用，`/status` 可用现有端点拼，但价值低 |
| — | `/resume` | 用户已决定：**不删、不增强**；只把它改成复用面板的合并数据源（P1 的一部分），消除编号口径不一致 |

## 5. 复现方法

```bash
# 判据：run 计数（出现即"发给模型"）
timeout 90 "$HDC" -t "$DEV" shell hilog > /tmp/h.log 2>&1 &
# 逐条：点输入框 → inputText "<cmd>" → 点发送 → sleep 6
grep -c 'run created' /tmp/h.log
```

坑（已写入技能）：
- `uitest uiInput longClick <x> <y>` 无时长参数，多传会被当 `displayId` 静默失效；
- WSL 调 Windows `hdc file recv` 必须 `cd /mnt/c/...`，且落地判据要查 WSL 路径；
- 竖屏 dump 时键盘会占满屏，需先 `keyEvent Back` 再 dump，否则只拿到键盘节点。
