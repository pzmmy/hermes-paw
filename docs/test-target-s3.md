# S3 测试目标声明（L3 验收用）

> 定位：S3（收口与开源）的**机器可验证测试目标锚点 + L3 真机验收口径**。
> 前置：L2 回归全绿（236 可跑，见下）是进入 L3 轮的条件。

## T0 前置（机器可校验，FAIL 即中止）

| 核查项 | 期望值 | 校验命令 |
|---|---|---|
| 项目标签 | `hermes-paw` | 宿主 git 目录下仅 hermes-paw 仓 |
| remote | 指向 hermes-paw bare repo | `git remote -v` |
| 代码锚点 | S3 主代码提交 `c6385d1` 在 HEAD 祖先链上 | `git merge-base --is-ancestor c6385d1 HEAD` → rc 0 |
| 代码锚点 2 | S3 文档/工具提交 `b4de667` 在 HEAD 祖先链上 | `git merge-base --is-ancestor b4de667 HEAD` → rc 0 |
| 页面集 | 23 个 .ets | `find entry/src/main/ets -name '*.ets' \| wc -l` → 23 |
| S3 特征文件 | 全部存在 | `ls entry/src/main/ets/net/ErrorText.ets tools/s3-selftest.py tools/arkts-lint.py tools/l3-error-sim.py LICENSE` |

S3 新增/变更文件（相对 S1 锚点 20 文件）：
- 新增 `net/ErrorText.ets`（统一错误文案，S3-a）
- 新增 `model/Multimodal.ets` + `media/PhotoPick.ets`（S2-a/b）
- 变更 `viewmodel/ChatVM.ets`（S3-a 8 处文案 + S3-b 退避恢复）、`viewmodel/SettingsVM.ets`（S3-a）、`pages/ChatPage.ets` / `pages/SettingsPage.ets`（S2 语音/图像 UI）

## L2 回归（236 侧，L3 轮前置门槛，全绿才进 L3）

| 项 | 命令 | 期望 |
|---|---|---|
| 接口层 | `python3 tools/api-selftest.py` | 26 PASS / 0 FAIL |
| 图像输入 | `python3 tools/s2-selftest.py` | 11 PASS / 0 FAIL（默认用仓内 tools/testdata 双色块 fixture） |
| 秘密/IP 扫描 | `python3 tools/s3-selftest.py` | 5 项 PASS |
| ArkTS 严格模式静态检查 | `python3 tools/arkts-lint.py` | 23 files, 0 findings |

## L3 验收（主控真机）

### (a) 四错误态复现（S3-a）

文案为 verbatim 口径（`net/ErrorText.ets`），调用处另带操作前缀（如"发送失败："）。

| 错误态 | 复现方法 | 期望文案（verbatim） |
|---|---|---|
| 401 | mock `--mode 401`（或真网关填错 Token） | 网关 Token 可能错误或已过期，请到设置页重新填写 |
| 5xx | mock `--mode 5xx` | 服务器异常，请稍后重试 |
| 超时 | mock `--mode timeout`（设置页测试连接 ~8s 出文案；聊天发送最长 ~30s） | 连接超时，请检查服务器是否在线 |
| 无法连接 | mock 停止后打同端口 / 填错端口 | 无法连接服务器，请检查网络连接与服务器地址 |
| 未配置 | 清空档案后点测试连接 | 服务器地址未配置，请到设置页填写 |

mock 用法（手机可达的宿主上，如 236）：

    python3 tools/l3-error-sim.py --mode 5xx --port 8378

App 侧：设置 → 编辑档案 → 地址 `http://<宿主>:8378` → 任意 Token → 保存 → 测试连接/发消息。
236 侧如需放行 mock 端口：`sudo ufw allow from <手机网段>/24 to any port 8378`。

### (b) 断网 30s 恢复自动重连（S3-b）

1. 正常会话中发起一个长任务（流式进行中）；
2. 停 mock（或断网）→ 流断开，进入恢复退避（2/4/8/16/30s 封顶）；
3. ≤30s 内恢复服务 → 自动重连续上，消息不重复（seq 门）；
4. 断网期间若有待审批卡：不重复弹卡、不消耗审批窗口（服务端 60s 真相源）；
5. 恢复后流成功打开 → 退避窗口重置。

### (d) 冷启动 ≤2s

杀进程 → 启动 → 对话页可操作（可输入/可点发送）计时。

### (e) 六里程碑回归

M0a（接口面）/ M1（会话+本地存储）/ S0（服务端工具+QR）/ S1（推送核心+扫码+接管）/ S2（片段输入）/ S3（收口）。
S1 行 a-d + 负例 ×4 按 `docs/test-target-s1.md` T3/T4 复跑；S2 按 `docs/test-target-s2.md` 复跑（端侧语音/图像各一条 + s2-selftest 证据）。

### (f) 双网段回归

家庭网 / 公司内网各完整走一遍（扫码 → 发消息 → 审批）。切网免重扫（档案持久化）。
环境前置同 S1：手机须可达该网段网关；家庭段若受宿主 WSL 转发限制（S1 轮 E-1 已知项），记环境非代码。

### 真机独占 5 项（S1 轮遗留，本轮一并跑完）

HUKS 加密存储 / 扫码 CAMERA 权限三件套（相机+相册+粘贴）/ 生物识别 / 安全键盘 / AP 隔离。

## 验收映射

a→L3(a) 5 态；b→L3(b)；c→s3-selftest（L2 自动）；d→L3(d)；e→L3(e)；f→L3(f)。
S3 全过 = 六里程碑收口，进入开源发布（D5，主控推 GitHub 干净仓库）。
