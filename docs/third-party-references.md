# 第三方引用与许可

本仓库为 MIT 许可（见 `LICENSE`）。产品代码是纯 ArkTS，**零第三方运行时依赖**；
下列引用仅涉及工具脚本与设计参考。

## 运行时 / 构建

| 组件 | 许可 | 位置 | 说明 |
|---|---|---|---|
| 无 | — | — | `oh-package.json5` 的 `dependencies` 为空，App 不链接任何第三方库 |
| hvigor / hvigor-ohos-plugin | DevEco Studio 自带 | `devDependencies` | 由 DevEco Studio 提供，仓库不锁版本（见 README「构建」） |

## 工具脚本

| 组件 | 许可 | 位置 | 说明 |
|---|---|---|---|
| segno（二维码生成） | BSD-3-Clause | `tools/_vendor/segno/`（许可原文 `tools/_vendor/segno-LICENSE`） | 仅 `tools/hermes-paw-qr` 使用；纯 Python、无外部依赖 |

## 设计参考（不包含第三方代码）

实现过程中参考过以下项目**公开的行为与能力清单**，未复制其代码：

| 项目 | 许可 | 参考点 | 处置 |
|---|---|---|---|
| [iHermes](https://github.com/2winter-dev/iHermes) | MIT | SSE 流式接收的健壮化思路（分块解析、序列号重放门） | 参考思路后自行实现；源码摘录**不入库** |
| [Conduit](https://github.com/cogwheel0/conduit) | GPL-3.0 | 能力清单对照（哪些交互值得做） | **只借思路，不复制代码**；为避免 GPL 传染，源码摘录**不入库**，仅本地存档 |

> 说明：2026-11-19 之前，本地仓库曾保存过上述两个项目的源码摘录用于比对（`docs/opensource-research/`）。
> 为满足 MIT 项目的分发合规要求，该目录已**移出仓库并本地归档**（不入库、不随发布包分发）；
> 本文件即对外声明。
