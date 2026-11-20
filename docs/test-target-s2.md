# HermesPaw S2-a（图片输入）测试目标

基线：S2-a 特性提交（2026-10-31，master）。范围：相册选图（免权限 PhotoViewPicker）
→ 客户端压缩（长边 1568 / JPEG q80 / base64）→ `POST /v1/runs` OpenAI 风格
messages input → 模型视觉回复。契约 2026-10-31 网关实证（E2E 通过）。

验收分层（同 S1 框架）：
- **L2**（236 直连 236:8377，`tools/s2-selftest.py` 等价复刻客户端逻辑）— 本批执行；
- **L3**（真机，与 S1 真机独占项同批执行，见 docs/test-target-s1.md 待裁项裁决）。

## L2 用例（tools/s2-selftest.py）

| 用例 | 内容 | 判定 |
|---|---|---|
| L2-00 | 建独立测试会话（POST /api/sessions） | 201 + session.id |
| L2-01 | parts 构造同构（离线）：text+image / image-only / 空 dataUrls→[] | 与 Multimodal.buildUserMessage 语义一致 |
| L2-02 | 全链路（文字+真实照片）：prepareImage 复刻管线（PIL，滤镜差异记录在案）→ 202 → 终态 | completed 且回复非空；**回复须人工对照原图**（证据包内打印回复前 400 字） |
| L2-03 | image-only 发送（无 text part） | 202 → completed 且回复非空（验证无 text 不 400） |
| L2-04 | 11 图越限（服务端 _IMAGE_LIMIT=10） | 400（error code 记录在案） |
| L2-05 | 文本回归：M1 纯字符串 input（selftest W-02a 形态） | 202 → completed（守护 createRun 签名放宽无回归） |
| L2-06a | image/* 头但坏字节（魔数嗅探失败） | 400 invalid_params（服务端真实拒绝路径，源码 commit_api_images 佐证） |
| L2-06b | 非图片 data URL（data:text/plain） | 202 透传（契约观察：服务端静默过滤、原样交模型；客户端恒发 image/jpeg 不触达，此用例锚定服务端当前行为） |

已知盲区：128MB 总量上限不实测（构造成本过高，以源码核验 _MAX_INBOUND_MEDIA_BYTES 为准）。

## L2 补充（S2-b，2026-11-01）

S2-b 无新增网关用例：重发 payload 形状 = S2-a 已验发送形状（L2-02/03/05 覆盖）；
停止/审批契约 = S1 已验（2026-10-31 回归 26/26 复核，W-03f/g、A-01/A-02）。
S2-b L2 口径 = 静态自检 + 重跑双回归（s2-selftest 11 + api-selftest 26）确认无破坏。

## L2 补充（S2-c，2026-11-01）

S2-c 无新增网关用例：语音走**端侧** CoreSpeechKit（网关无音频入口，
capabilities `audio_api:false`，session_api_media 仅 image_url——S2-a 已锚定），
发送环节复用 S2-a 文本发送形状。
S2-c L2 口径 = 静态自检（括号配平/禁用语法/@kit 导入）+ 重跑双回归
（s2-selftest 11 + api-selftest 26，2026-11-01 执行：11/11、26/26 全绿）。

## L3 用例（真机，与 S1 真机独占项同批）

| 用例 | 内容 | 判定 |
|---|---|---|
| L3-01 | 相册多选（上限 10，满额后提示） | chip 行缩略图 + ✕ 单张可删 |
| L3-02 | 拍照/相册图发送 → 气泡即时缩略图 + 模型正确回复 | 全链路真机复现 L2-02 |
| L3-03 | 降级路径：>20MB 大图 / 损坏图 | notice「图片处理失败…」，纯文本照发或整单中止（无文字时），pending 行保留可重试 |
| L3-04 | image-only 发送 | 气泡 (图片) 占位 + 模型回复 |
| L3-05 | 会话切换 / 新建会话 | pending 附件行清空（不泄漏到其它会话） |
| L3-06 | 历史重拉后缩略图 | 已知限制：imageUris 瞬态不落库 → 重拉后气泡仅文字，报告记 P2（后续批次评估 schema 扩展） |
| L3-07 | 用户气泡长按→复制（S2-b） | 「已复制」提示；粘贴板内容与气泡文本一致 |
| L3-08 | 用户气泡长按→重发（S2-b） | 新建 run 内容一致（内存带图则连图、重拉后纯文本）；运行中菜单不出现重发项 |
| L3-09 | 运行中长按气泡→停止生成（S2-b） | S1 确认弹窗出现，确认后停止生效，部分回复保留 |
| L3-10 | 审批 pending 长按气泡→处理审批（S2-b） | 四选项框（本次/本会话/固定/拒绝），与卡片 4 按钮同 VM 提交路径 |
| L3-11 | 首次点🎤→授权并说一句话→VAD 断句自动结束（S2-c） | 文本填入输入框，内容与发音一致；「识别完成」提示 |
| L3-12 | 拒绝麦克风权限（S2-c） | 提示引导去系统设置，输入框与界面不变（不进入录音态） |
| L3-13 | 说半句后点⏹（S2-c） | 采纳已说部分进输入框 |
| L3-14 | 说半句后点✕（S2-c） | 丢弃，输入框不变，回到 idle |
| L3-15 | 持续讲话 30s（S2-c） | 到上限自动结束并交付已识别文本；无音频则超时结束+「未识别到语音」 |
| L3-16 | 两句中间停顿（S2-c，选做） | 两个子句经 isFinal 拼接交付，无丢失 |

## 证据与产物

- 证据包：`evidence/s2-selftest-*.jsonl`（gitignore，含 base64 截断与回复头段）
- 契约锚点：`model/Multimodal.ets` 头部注释（2026-10-31 E2E 结论 + 服务端限额出处）
- 回归基线：`tools/api-selftest.py` 25 用例（S1 确认基线，本批不改动其断言）
