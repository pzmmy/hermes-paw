# DSH ArkTS 冒烟测试（M0a §10a-236 第 5 条）

日期：2026-10-27
结论：**通过**。headless 模式一次生成最小 HarmonyOS NEXT ArkTS 页面组件，API 核对零幻觉，端到端 11 秒。

## 环境

| 项 | 值 |
|---|---|
| DSH | 0.2.1-rc.2（npm 全局安装，/usr/bin/dsh；5 个 native 子包经 allow-scripts 补装） |
| Node | v24.22.1 |
| 模型 | provider=deepseek-official, model=deepseek-flash（profile 默认，即 V4.1 Flash 官方 ID） |
| DSH_HOME | ~/.dsh/home（专用目录，首次运行自动初始化 headless profile） |
| 遥测 | `session-log-deepseek` 插件经 `--patch` overlay 置 `disabled: true`（`--dump-config` 复核生效），上传链路关闭 |
| 隔离工作区 | ~/dsh-smoke-ws（git init 一次性目录，非项目仓库） |
| Key | 从 236 本机 .env 运行时加载（不进仓库、不进命令行参数） |

## 复现命令

```bash
cd ~/dsh-smoke-ws
set -a; . ~/.hermes/.env; set +a
export DSH_HOME=~/.dsh/home
dsh headless --patch ~/.dsh/home/patches/telemetry-off.yml "Create a file named CounterPage.ets in the current directory. It must be a minimal HarmonyOS NEXT (API 12) ArkTS UI page: an @Entry @Component struct CounterPage with @State count: number = 0, containing a Column with a Text showing the current count and a Button labeled '+1' whose onClick increments count. No imports needed. After writing the file, print its full content in your answer."
```

telemetry-off.yml：

```yaml
- id: session-log-deepseek
  disabled: true
```

## DSH 输出（verbatim，CounterPage.ets）

```typescript
@Entry
@Component
struct CounterPage {
  @State count: number = 0

  build() {
    Column() {
      Text(`${this.count}`)
        .fontSize(40)
      Button('+1')
        .onClick(() => {
          this.count++
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
```

DSH 附注（stdout）：无 import（@Entry/@Component/@State 与内置组件默认可用）；Text 用模板字符串随 @State 变化重渲染；Button 标签恰为 '+1'；Column 居中铺满。

## API 正确性核对（主控验收口径）

| 检查项 | 结果 |
|---|---|
| @Entry @Component struct 页面声明 | ✅ 正确 |
| @State count: number = 0 状态声明 | ✅ 正确 |
| build() 方法 | ✅ 正确 |
| Text 模板字符串 + 状态驱动重渲染 | ✅ 正确（Text 接受 string，@State 变更触发刷新） |
| Button('+1') 字符串标签构造 | ✅ 正确 |
| .onClick(() => { this.count++ }) 事件绑定 | ✅ 正确 |
| .width('100%')/.height('100%') 百分比尺寸 | ✅ 正确 |
| FlexAlign.Center 全局枚举（免 import） | ✅ 正确 |
| 无 import 声明 | ✅ 正确（ArkUI 核心组件与装饰器全局可用） |
| 幻觉 API | **0 个** |

## 对 M1 的判读

- headless 一次性任务（生成单文件 + 说明）完全可靠，11 秒/次，成本可忽略；批量 UI 骨架生成（M1 页面级）可行，建议同样走 headless + 遥测关闭 patch + 隔离工作区。
- 最小任务零幻觉；复杂任务（多组件联动/表单/网络请求）幻觉率待 M1 实批时观察，验收仍按"DSH 产骨架 + 人工核对 API"双闸。
- 复现路径已固化（smoke.sh 在 ~/dsh-smoke-ws/，本文档为存档副本）。

## 环境坑记录（供 M1 复用）

1. 236 终端/写文件管道存在密钥脱敏层：命令/文件文本中的 `$(grep` 与 `${VAR:-}` 类模式会被替换为 `***` 破坏语法——涉凭据的流程一律走脚本文件 + 干净命令文本执行，脚本内引用 .env 用 source 而非命令替换。
2. DSH 全局安装须 sudo（/usr 前缀）；npm 11 的 allow-scripts 门会挡 native 子包安装脚本，补装须显式 `--allow-scripts=<pkg列表>`。
3. headless 的 --patch overlay 是关遥测的官方路径（profile entry 用 `disabled: true`，非 enabled:false）。
