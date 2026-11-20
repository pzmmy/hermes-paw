# 文档索引（简体中文）

本目录是 HermesPaw 的设计、验证与运维记录。HermesPaw 是 [Hermes Agent](https://hermes-agent.nousresearch.com/docs)
网关的鸿蒙（HarmonyOS NEXT）客户端。

> 英文索引：[`README.en.md`](README.en.md) ｜ 用户文档：[`../README.md`](../README.md) / [`../README.en.md`](../README.en.md)
>
> 本页只解决一个问题：**每篇文档回答什么、给谁看、是否仍可作为依据**。
> 正文不保证随代码同步翻译——这里给出判断依据，避免读者把过时记录当现状。

## 建议阅读顺序

| # | 文档 | 回答什么问题 | 给谁看 | 状态 |
|---|---|---|---|---|
| 1 | [`refactor-design.md`](refactor-design.md) | **为什么这样设计**：传输主从（getRun 轮询为基线、SSE 只做增强）、run 生命周期与放弃条件、会话/标题契约、审批流、体积与依赖红线。v1.6 签发版。 | 评审架构决策的人 | 📌 设计基线，权威 |
| 2 | [`impl-status.md`](impl-status.md) | **实际做成了什么、拿什么证据验收**：S1…S11 每一步的构建耗时、门禁结果、真机日志，以及**被证伪的结论**（例如 SQLite PRAGMA 调优实测无效后回退）。 | 贡献者、评审者、后续维护者 | 🔄 活文档，每步更新 |
| 3 | [`server-setup.md`](server-setup.md) | **网关侧怎么配**：profile、长效 key、办公网监听、防火墙，以及 `tools/hermes-paw-qr` 打印的配对二维码。与主 README 的步骤互为补充。 | 跑网关的人 | ✅ 运维手册，真机验证过 |
| 4 | [`slash-command-support.md`](slash-command-support.md) | **App 支持哪些 Hermes CLI 斜杠命令**（真机实测矩阵）：5 条本地映射、7 条显式拒绝，其余按普通消息转发给模型——因为网关 REST 面不派发斜杠命令。 | 报"命令没反应"的用户；贡献者 | ✅ 实测矩阵 |
| 4b | [`channel-comparison.md`](channel-comparison.md) | **为什么不用现成的企微/微信通道**：两条链路的结构差异、十项能力逐条对比（安装/网络/推送/审批/停止/插话/历史/长输出/多网关/外泄面）、以及审批为什么必须做成 60 秒卡片。每条都给了网关源码位置便于复核。 | 想判断「该用哪个」的人；软文读者 | ✅ 现行，随网关版本复核 |
| 5 | [`user-auth-and-settings-design.md`](user-auth-and-settings-design.md) | **邮箱验证码登录的设计与为何关闭**：网关侧 P1 已回退、客户端 P2 休眠（探针 404 → legacy 模式）、只上了精简的 P3。含重新启用路径。 | 评审鉴权相关改动的人 | ⏸️ 按决策休眠（D6） |
| 6 | [`third-party-references.md`](third-party-references.md) | **许可边界**：本仓库 MIT、零第三方运行时依赖，以及 iHermes / Conduit / segno 的引用方式与限制。 | 分发者、下游打包、法务审阅 | ✅ 有效约束 |
| 7 | [`test-target-s1.md`](test-target-s1.md) · [`-s2`](test-target-s2.md) · [`-s3`](test-target-s3.md) | **可机判的验收目标**：每阶段在动手前先写死"做到什么算完"，避免"完成"变成主观判断。可作为扩展本项目时的模板。 | 写测试的人 | 🗄️ 历史，作为范例仍有效 |
| 8 | [`s3-c-token-recheck.md`](s3-c-token-recheck.md) | **Token 存储复核**：静态验证凭据只落在安全存储，零代码改动。 | 安全评审者 | 🗄️ 历史证据 |
| 9 | [`dsh-smoke-arkts.md`](dsh-smoke-arkts.md) | **ArkTS 冒烟实验**：headless 模式下模型驱动能否一次产出可编译、API 无幻觉的鸿蒙组件。交代了本项目部分代码的产生方式。 | 好奇的贡献者 | 🗄️ 历史 |

## 本目录的行文约定

- **证据代替形容词。** 结论必须挂一个可核对的物件：构建耗时、门禁条数、带时间戳的日志行、设备布局 dump。
  拿不出物件的，一律标成"假设"。
- **被证伪的结论保留，不删。** 改动上机实测无效果时，既回退代码，也留下记录（见 `impl-status.md` 里
  SQLite PRAGMA 的那一段）。删掉记录等于给同一个坑留第二次机会。
- **设计文档不写代码，实施记录不改设计。** 两者冲突时以设计文档为准，并回头修正实施记录。
  已签发文档的正文不动（改正文会让文末登记的 md5 对不上），进度与偏离写进实施记录。
- **零内部标识。** 主机名、内网地址、Token、个人数据在随仓库分发的内容里一律不出现，由门禁逐次拦截。

## 代码级事实去哪找

| 想确认 | 看哪里 |
|---|---|
| 怎么构建、签名、安装 | [`../README.md`](../README.md) 的「构建」段 |
| 手机上到底跑着什么 | `entry/src/main/ets/` — `viewmodel/`（状态机、轮询策略）、`net/`（网关 API、SSE）、`pages/`（界面） |
| 不上设备怎么验证行为 | `tools/*-selftest.py` + `make test` |
| 上设备怎么验证 | `entry/src/ohosTest/`（Hypium，`make test-device`）+ `tools/ostest.sh` |
| 靠什么防回归 | `tools/arkts-lint.py`、`tools/i18n-selftest.py`、`tools/s3-selftest.py` —— 全部挂在 `make test` 里 |
