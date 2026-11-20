# S3-c · Token 存储复核清单

结论：**零代码改动**。Token 存储链路在 M1+批次2 已按设计红线落地，S3 只做复核与静态验证。

## 复核项

| # | 复核项 | 现状 | 证据 |
|---|---|---|---|
| 1 | 加密原语 | HUKS AES-256-GCM，CMK `hermespaw_cmk_v1`（TEE 驻留，密钥不出安全芯片） | `store/TokenVault.ets` |
| 2 | 加固批次 | batch2-r5 加固 + r9 真机修复 12000011（HUKS 权限/参数） | 批次2 提交记录 |
| 3 | 日志纪律 | hilog 全程只打 op+code（如 `vault: getPreferences failed (code=...)`），不打任何 token 数据 | 全仓 grep + `tools/s3-selftest.py` 检查 4 |
| 4 | "诊断导出" | **该功能不存在**——ScanVM 四因诊断输出为明文文案（原因+动作），无 token 导出路径 | `viewmodel/ScanVM.ets` 代码走查 |
| 5 | 明文红线 | 明文 token 不落 SQLite、不落文件、不落日志（P1-4）；仅存于 HUKS 加密态 + ApiClient 内存字段 | 架构走查 |

## 静态验证（机器可重跑）

```
python3 tools/s3-selftest.py
# 检查 4: hilog 参数位零密钥变量 → PASS
```

检查 4 规则：剥离 hilog 行的单引号格式串后，参数位出现
`token/formToken/envelope/plain/cipher/nonce` 变量即 FAIL
（格式串文本里的 "saveToken failed" 等操作名/状态描述不误报）。

## 剩余风险（已知、可接受）

- 内存态 token（ApiClient 字段）在进程存活期可被同进程代码访问——单应用 HAP、无第三方 SDK 注入面，局域网工具定位下可接受。
- HUKS 密钥与设备绑定：换机需重填 token（设计如此，不做跨机迁移）。
