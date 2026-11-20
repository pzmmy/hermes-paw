# 服务端配置手册（Hermes 网关 × HermesPaw）

> 与脚本 `tools/hermes-paw-qr`（零依赖，系统 python3 直接跑，无需 pip）同口径。
> 口径来源：主方案 v2.6 §7.7 + §4.8（委托式接入）+ 设计文档 `m2-qr-design.md` §7（安全边界，诚实口径）。
> 验证状态：①-⑤⑦-⑨ 于 236（Hermes v0.22.5）原样可执行（2026-10-30 实测）；S0 脚本 46/46 回归 + 实机验收 2026-10-30；S1.5 新 flags（--prompt / 非 TTY --png）2026-11-15 非 TTY 测试组全绿；v2.6.6 单一档二维码（去 --admin/--user/--admin-yes 与 guest 自动建档）2026-11-16。

## 0. 前置条件（写死版本下限，别写"最新版"）

- Hermes ≥ v0.22.5（api_server / runs 族契约）
- systemd（hermes gateway 以 service 运行）
- python ≥3.12（网关本身；出码脚本零依赖，系统 python3 即可）
- 手机与服务器同网段（示例 192.0.2.0/24，改成实际网段）

## 1. 一键路径（推荐）

```
cd ~/git/hermes-paw
tools/hermes-paw-qr --list      # 预检：四态（enabled/host/key/监听）+ profile 状态
tools/hermes-paw-qr --apply     # 四态对账缺啥补啥（②+③；幂等）
tools/hermes-paw-qr             # 出码（单一档 = default profile + 主 key；不分档）
```

### 委托接入路径（App 引导，v2.6 S1.5；手机用户推荐）

App「首次接入（让 Hermes 代配置）」页组装自包含提示词（**不含 IP/端口/key**），用户贴进自己的 Hermes 对话（CLI / 企业微信 / Web，通道无关）；agent 按序执行：

1. 定位 `tools/hermes-paw-qr`（找不到 → 停下请用户提供单文件，公仓就绪前不自动 clone）；
2. `--apply` 四态对账（需重启 → 把重启命令交给用户重启，**agent 绝不自己重启**）；
3. 出码：`--name "<名>" --png /tmp/hermespaw-qr.png`（单一档 = default profile + 主 key）；
4. 回传 PNG（通道不可发图 → `--json` 取 URI 文本贴对话）；
5. 用户扫码完成后提醒删除 /tmp/hermespaw-qr.png。

非 TTY `--png` 语义（本版新增，供 agent 的 terminal 工具用）：只写 PNG 文件，stdout 零 URI / 零 ASCII 码（诊断走 stderr），rc=0——P1-3 防 key 落日志的意图保持。

`--apply` 语义（2026-10-30 实测）：

- 逐项对账：`platforms.api_server.enabled`（false→true）→ `extra.host`（回环→0.0.0.0）→ 主 key 三分支（可用≥16 保留 / 弱 key 覆盖+备份+警告 / 缺失新建 64hex chmod 600）→ 复验端口监听。
- 任何改动（config 或 .env，均为网关启动时加载）→ **退出码 2 + 提示人工重启网关；脚本绝不自己重启**。
- 幂等：二次运行零改动 + rc=0（236 实测：连跑两次 rc=0，config.yaml/.env 哈希不变）。
- 注意：`--apply` 只对账 default profile 四态；出码直接用 default + 主 key（v2.6.6 单一档，不再自动建 guest；两档设计已作废，确需受限 profile 时参照方案 §4.7 留档的两档设计细节手动搭建）。

### 全 flags 一览（与脚本 `--help` 一致）

| flag | 含义 |
|---|---|
| `--apply` | 四态对账：enabled/host/key/端口，缺啥补啥；需重启网关时只通知不重启（幂等） |
| `--list` | 列出本机可出码的 profile 及状态（不出码、不显示 key） |
| `--host ADDR` | 覆盖自动探测的地址（如 192.0.2.50）；自动探测按接口名过滤 TUN（如 100.64.x） |
| `--name NAME` | 档案显示名，默认自动生成（profile 名） |
| `--once` | 打印后按回车清屏（降低 QR 泄露面） |
| `--json` | 只输出 URI（不打印二维码；诊断信息走 stderr，URI 独占 stdout）；**与 `--png` 互斥（同用 rc=1）**，且仅 gen 有效（--prompt/--apply/--list 下 rc=1） |
| `--png PATH` | 同时输出 PNG（segno 纯 Python 生成，无 PIL）；非 TTY 环境仅写文件（stdout 零 URI，诊断走 stderr）；**与 `--json` 互斥（同用 rc=1）** |
| `--prompt` | 打印接入提示词（v2.6.6 单一档模板；与 App OnboardPage 同一模板，改一处必同步另一处）；不出码、不触配置 |
| `--no-selftest` | 跳过 /v1/models 自检（仅排障用） |

### 出码 URI 契约（6 字段，App 端按此解析）

```
hermespaw://setup/1?a=<ip:port,...>&k=<key>&pf=<profile>&min_app=0.1.0&name=<百分号编码>
```

- `a`：全部可探测本地地址，逗号分隔（按优先级），App 逐个 2s 探测取首个可达；地址内 `:` 与 `,` 保留原样（合法 query 字符），其余参数值百分号编码。
- `k`：对应 profile 的 API_SERVER_KEY（64 位 hex）。
- `pf`：profile 名；当前出码恒为 default → URL 前缀 /p/default/（单一档）。
- `min_app`：最低 App 版本（当前 0.1.0；无升级通道，硬编码 App）。
- `name`：档案显示名（百分号编码）。
- 出码前强制 Bearer 自检（GET /p/<profile>/v1/models，命名 profile 必须带前缀，401/超时不出码）；非 TTY 环境拒绝打印 ASCII 码 / URI（防 key 进日志），例外为 `--json`（URI）与 `--png`（仅文件，stdout 零 URI）。

## 2. 手动路径（①-⑨ 逐条示例）

逐条命令原样可执行文本见 **README「服务端配置（Hermes 网关）」章**（同一来源，不在此重复，防双份漂移）。要点索引：② 开 api_server 三行 · ③ 主 key 三分支 · ⑤ 防火墙（Linux/WSL/Windows 三版）· ⑦ 出码 · ⑧ 重启（必须人工）· ④（v2.6.6 起作废：两档 guest 设计取消，细节留档方案 §4.7）。

## 3. 安全边界（诚实口径，照抄，不得自欺）

1. **内网 ≠ 安全边界**。公司网内任何设备只要知道 IP:端口就能打 8377；
   门在 **key + 防火墙限源段 + 关工具** 三者组合。
2. **这是 API 层 + profile 配置层隔离，不是 OS 沙箱**：同一个 OS 用户、同一个文件系统。
   安全来自「关工具」，**不能宣传成「进程隔离」**。
3. **公司 WiFi AP 隔离——PASS（2026-10-30 主控真机）**：公司 AP 无隔离，手机可见文件
   目录、可直连。未来若 IT 开启隔离（盲区 2）：App L1 不可达文案给指引「请确认手机与
   电脑同网段；企业 WiFi 可能开启 AP 客户端隔离，请联系 IT 关闭」。
4. **二维码泄露面**：终端 scrollback、tmux buffer、投屏、截图、转发的图片。
   缓解 = 一次一人一码、`--once` 打印后清屏、默认不落盘。**二维码 = 网关主凭据（v2.6.6
   单一档）**：泄露 → 换主 key（高成本 = 网关重启 + 所有手机档案失效），QR 图片仅在
   可信设备/可信渠道分发，不得投屏/截图/转发。
5. **同一个二维码含一把长效 key：多台设备扫同一个码 = 共用一把 key，无法区分到人**。
   本期默认部署形态（自有 Hermes + 可信通道分发）；确需按人隔离 key 时按人出码
   （各自独立 key），代价是管理 N 份 key。

## 4. 排障表（现象 → 判定 → 处置）

| 现象 | 判定依据 | 处置 |
|---|---|---|
| 手机打不开 8377 | ufw.log 里 DPT=8377 有 BLOCK 计数 | 加 ufw 规则（⑤） |
| 127.0.0.1 连不上 | `ip -br link` 有 loopback0 | `sudo ufw allow in/out on loopback0` |
| 本机打 LAN IP 不通 | hairpin 特例，不代表外部不通 | 直接拿手机验 |
| 码里地址是 100.64.x | WSL DNS 隧道地址 | 脚本按接口名过滤（已修，写进文档防回归） |
| 自检 401 | 命名 profile 必须打 /p/<name>/ 前缀 | 用脚本出码，别手拼 URL |
| 8377 完全没在听 | `ss -lntp` 输出无 8377 监听行、config 已 enabled=true | 配置改了没重启网关 → `hermes gateway restart`（脚本只提示、绝不自己重启） |

## 5. S0 验收清单（主方案 §8.3）

| # | 验收项 | 状态 |
|---|---|---|
| a | 裸机 15 分钟实测（手机扫码 + 对话一条） | ⏳ 主控待做（2026-10-30 晚后） |
| b | `--apply` 幂等（二次运行零变更） | ✅ 2026-10-30 236 实测：连跑两次 rc=0，config.yaml/.env 哈希不变 |
| c | README 命令原样可执行 | ✅ 2026-10-30 236（v0.22.5）①-⑤⑦-⑨ 原样 |
| d | 排障表 6 项 | ✅（本文档 §4） |

回归测试：46/46（stub E2E 22 项 + 新逻辑验证 5 项 + V2 回归 5 项 + help 全 flags 等；测试脚本 `hp-run-regress.py`，`/usr/bin/python3` 运行）。
