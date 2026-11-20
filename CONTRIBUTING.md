# 参与 HermesPaw

先说清楚这个项目是什么：**给已经在跑 Hermes 网关的人用的手机客户端**，只在同一局域网内工作，不做公网中继。如果你没有 Hermes 网关，装了也用不了。

改动之前请先读 [`docs/refactor-design.md`](docs/refactor-design.md)（为什么这样设计）和 [`docs/impl-status.md`](docs/impl-status.md)（已经做了什么、哪些结论被证伪）。

---

## 环境

| 需要 | 版本 | 说明 |
|---|---|---|
| Python | ≥ 3.12 | 所有自测脚本和工具是纯标准库，不需要 pip install |
| DevEco Studio | 6.x（HarmonyOS 7 SDK） | 编译 HAP、跑设备测试要用 |
| 手机/模拟器 | HarmonyOS 5.0+（API 12+） | 只有跑设备测试时才需要 |

不需要 Node.js，不需要 npm。

## 三种检查，按需选

### 1. 静态自测（无设备、无网关、无凭据）

```bash
make test
```

逐个跑 `tools/*selftest*.py`，目前 17 组。这是提交前的最低要求，也是 CI 里跑的那一套。

其中 `api-selftest.py` 与 `s2-selftest.py` 需要真实网关（`API_SERVER_KEY`）。拿不到 key 时它们按约定 **以退出码 77 退出 = SKIP**，`make test` 会显示 `SKIP` 并计入"跳过"组数，**不计为失败**（与 `make l2` 同一约定："未测"不等于"失败"）。所以 CI 上你会看到 2 组 SKIP，本地有网关时才会全量实跑。

```bash
make lint    # arkts-lint：括号平衡、build() 内局部变量、重复声明、裸 hilog
make scan    # 零凭据 / 零内网 IP 扫描（扫 git 跟踪的文件）
```

`make scan` 请务必在 push 前跑——历史上有多份文档因为写了内网地址被拦下。

### 2. 导出演练（改了文件结构、图片、许可相关时跑）

```bash
make export
```

生成开源导出包，并在包里再自检一遍（单文件 >100 KB、icon 一致性、零内部标识等）。

### 3. 设备测试（改了 UI 或状态机才需要）

```bash
# 打测试包
hvigorw --mode module -p module=entry@ohosTest -p product=default assembleHap

# 装到设备上跑（HDC 用你本机的 hdc 可执行文件路径）
HDC=/path/to/hdc TARGET=<ip:port> bash tools/ohostest.sh
```

用例在 `entry/src/ohosTest/ets/test/List.test.ets`，目前 18 个，覆盖标题派生、空标题兜底、轮询节拍、斜杠命令解析。

## CI 做什么、不做什么

`.github/workflows/selftest.yml` 在 Ubuntu 上跑 `make test` 和 `make scan`。

**它不编译 HAP。** `hvigor` 由 DevEco Studio 提供，ohpm 公共仓库里没有这个包，GitHub runner 上装不出来。所以编译和真机验证必须在本地做——PR 里请附上你本地的构建输出。

这不是偷懒，是现状。看到 CI 绿勾不等于"能编译"，只等于"静态检查过了"。

## 代码规则

这几条是硬性的，`make test` / `make lint` 会拦：

1. **ArkTS 里不许用模板字符串**（反引号），用字符串拼接。lint 会报。
2. **`throw` 要指定类型**：`catch (err)` 里不能直接 `throw err`，先 `let e: ApiError = err as ApiError` 再抛。
3. **不许直接调 `hilog`**：全仓唯一出口是 `utils/LogSafe.ets`，方法只有 `d/i/w/e` 四个单字母。
4. **界面文案不许硬编码中文**：走 `Msg.t('key')`，key 进 `resources/{base,zh_CN,en_US}/element/string.json`，三套 key 必须一致。`tools/i18n-selftest.py` 会查。
5. **资源名只允许 `[a-zA-Z0-9_]`**，不能带点号。
6. **单文件不要超过 100 KB**（`s3-selftest` 拦，白名单见 `SIZE_WHITELIST`）。`ChatVM.ets` 另有一条 102,400 B 的团队预算，加逻辑前先想清楚放哪个文件。

## 提交与 PR

- 提交信息用 `feat:` / `fix:` / `docs:` / `chore:` 前缀，正文里写清**怎么验证的**（构建耗时、门禁条数、真机日志行）。
- PR 描述请包含：
  - `make test` 的输出（贴末尾几行就够）
  - 改了 UI 的话，附一张截图或一段录屏
  - 改了行为的话，说明哪个门禁或测试覆盖了它
- 涉及审批、传输、认证的改动，请在 PR 里说明对安全边界的影响。这个项目的安全模型很简单：**只在内网、只走 Bearer key、审批默认拒绝**，请不要削弱它。

## 不接受的改动

- 把局域网直连改成公网中继或第三方 IM 转发
- 引入第三方运行时依赖（现在 `dependencies` 是空对象，希望保持）
- 为了"看起来更快"加动画或骨架屏，但没有实测数据
- 把审批窗口默认拒绝改成默认允许

## 文档

- 设计基线：`docs/refactor-design.md`（签发件，正文不动）
- 实施记录：`docs/impl-status.md`（每个改动写这里，含被证伪的结论）
- 与官方 IM 通道的对比：`docs/channel-comparison.md`
- 推广稿与发布清单：`docs/promo/`

## 许可

提交即表示你同意以 [MIT](LICENSE) 许可发布你的贡献。

### 改到轮询 / 取数链路时

除 `make test` 外，还要跑真机回归（断言自适应拍距，不看代码长相）：

```bash
HDC="/path/to/hdc" TARGET=<ip:port> make poll-verify
```

它会发一条会长回答的消息、抓 28 秒 hilog，校验 `2s -> 4s -> 5s` 的降频曲线与拍点数。
`tools/poll-scheduler-selftest.py` 里另有一层不用设备的纯逻辑校验（含失败用例的状态机镜像）。
