# 发布清单（PUBLISH）

两份成品：

| 文件 | 平台 | 状态 |
|---|---|---|
| [`zh-publish.md`](zh-publish.md) | 华为开发者社区 | 正文可直接粘贴；**图片需手动上传** |
| [`en-publish.md`](en-publish.md) | dev.to | 带 front matter；`published: false`，确认后再改 true |

稿源（供修改）：[`zh-main.md`](zh-main.md) · [`en-main.md`](en-main.md) · 提纲 [`outline.md`](outline.md)

标题（已定）：
- 中文：**给 Hermes Agent 写一个鸿蒙客户端：审批、插话，和被放弃的流式输出**
- 英文：**I built a HarmonyOS client for Hermes Agent — and gave up on streaming output**

---

## 一、华为开发者社区（中文首发）

1. **标题**：用上面那行；正文里不要再写 H1（发布版已去掉）。
2. **摘要/简介**（社区表单里通常有）：建议填
   > 一个业务主管在会议室里，只能看着 Hermes 的审批窗口倒计时。为了这件事，我给 Hermes Agent 写了个鸿蒙客户端：审批卡片、`/steer` 插话、run 状态与时间戳；以及为什么最后放弃了流式上屏。
3. **图片**：正文里有一处占位
   `> 📷 配图位置：demo-zh.gif（发布时请上传该 GIF…）`
   → 把 `docs/screenshots/demo-zh.gif`（77.6 KB）上传到社区图床，用它替换这一整行。
4. **代码块**：全部已标注语言（`bash` / `text`），社区编辑器里如丢失高亮不影响阅读。
5. **标签**建议：`HarmonyOS`、`ArkTS`、`AI Agent`、`开放源代码`（按社区实际可选词调整）。
6. **结尾**保留仓库链接与三篇文档指引（已写进正文）。
7. **发布后**：把文章 URL 记到本文件末尾的「发布记录」。

> 注意：社区编辑器对**表格**支持一般。本篇正文没有表格，只有代码块、列表和引用块，粘贴后基本不会变形。

## 二、dev.to（英文）

1. front matter 已写好，**只需改 `published: false` → `true`**。
2. `tags` 上限 4 个，现为 `harmonyos, ai, arkts, opensource`（dev.to 要求小写、无空格）。
3. `canonical_url` 已指向仓库，避免与 GitHub 争 SEO。
4. 图片用的是 raw 直链，已实测 `200`（93,856 B 与仓库一致），**无需上传**：
   `https://raw.githubusercontent.com/pzmmy/hermes-paw/main/docs/screenshots/demo-en.gif`
5. 封面图可留空（dev.to 会取正文第一张图）。
6. **发布后**：把 URL 与 canonical 状态记到「发布记录」。

## 三、建议顺序

1. 中文先发（华为社区）——国内读者主要在社区；
2. 24 小时内英文发 dev.to（避免同一时间两条线都要盯评论）；
3. 若社区反响好，再把中文稿转载到掘金 / 腾讯云社区，**注明首发链接**。

## 四、发布前必须守住的四条

1. **不出现内网信息**：正文已过门禁（零内网 IP / 零密钥 / 零内部标识），改动后请重跑
   `python3 tools/promo-selftest.py`。
2. **不夸大能力**：只局域网可用、无推送、做不到流式上屏——这三条已在正文主动交代，**不要删**。
3. **数字不要手改**：`639.3 秒`、`19611 tokens`、`约 15 ms`、`206 处 / 345 key`、`300 秒`，都有仓库记录；
   改数字必须同时改证据，否则 `promo-selftest` 会红。
4. **GIF 无 PII**：现有两版已逐帧核过（无内网 IP、主机名、人名、密钥）；重新录制后要再看一遍。

---

## 发布记录

| 日期 | 平台 | 标题 | URL | 备注 |
|---|---|---|---|---|
| — | 华为开发者社区 | — | 待发布 | — |
| — | dev.to | — | 待发布 | canonical 指仓库 |
