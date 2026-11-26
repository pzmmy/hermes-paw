#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""resilience-selftest —— 2026-11-26 三条韧性改造的防回归门禁。

覆盖：
  A. 幂等键：POST /v1/runs 带 Idempotency-Key，且 ApiClient 支持调用方自定义头
  B. 401/403 分类：轮询失败里凭据错误必须先于「连接失败计数」处理，且文案指向登录
  C. 幂等键生命周期：同内容重试复用键；内容变了换键；受理后清键

为什么是静态断言：ArkTS 在本机没有可执行的编译/运行环境（CI 也只有 arkts-lint）。
本门禁断言的是「关键分支还在、顺序没被调换」，不绑具体实现形状（不比对整段文本）。
行为层面的验证靠真机：发送断网重试不产生第二个 run；密钥失效 6 秒内出登录提示。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / "entry/src/main/ets"
CHAT_VM = ETS / "viewmodel/ChatVM.ets"
API_CLIENT = ETS / "net/ApiClient.ets"
RUNS_API = ETS / "net/RunsApi.ets"

failures: list[str] = []
checks = 0


def chk(cond: bool, name: str, detail: str = "") -> None:
    global checks
    checks += 1
    if cond:
        print(f"  OK   {name}")
    else:
        print(f"  FAIL {name}" + (f"：{detail}" if detail else ""))
        failures.append(name)


def read(p: Path) -> str:
    if not p.exists():
        failures.append(f"缺文件 {p}")
        print(f"  FAIL 缺文件 {p}")
        return ""
    return p.read_text(encoding="utf-8")


def main() -> int:
    api = read(API_CLIENT)
    runs = read(RUNS_API)
    vm = read(CHAT_VM)

    print("[A] 幂等键 —— 请求侧")
    chk("extraHeaders" in api, "ApiClient.request 接受 extraHeaders")
    chk("Object.keys(extraHeaders)" in api, "doOnce 把 extraHeaders 合并进 header")
    chk("Idempotency-Key" in runs, "RunsApi 提到 Idempotency-Key")
    # 只认「真正写头」的赋值形态：注释里出现同名字样不算（负向对照实测过）。
    chk(re.search(r"\[\s*'Idempotency-Key'\s*\]\s*=", runs) is not None,
        "RunsApi 真的把 Idempotency-Key 写进请求头（非注释）")
    chk("idempotencyKey" in runs and "extra =" in runs, "RunsApi 按空串决定是否带头（兼容旧行为）")

    print("[B] 401/403 —— 凭据错误不当作连接故障")
    # 顺序断言：在本文件里，401 判定必须出现在 failStreak 自增之前。
    i_auth = vm.find("ae.code === 401")
    i_streak = vm.find("this.failStreak = this.failStreak + 1")
    chk(i_auth != -1, "轮询失败里有 401/403 分支")
    chk(403 in [int(x) for x in __import__("re").findall(r"ae\.code === (\d+)", vm)],
        "403 与 401 同等处理")
    chk(i_auth != -1 and i_streak != -1 and i_auth < i_streak,
        "401/403 判定先于失败计数（顺序不可调换）",
        f"401@{i_auth} streak@{i_streak}")
    chk("'auth-failed'" in vm, "收口 how 使用独立值 auth-failed")
    chk("this.error = Msg.t('m_vm_login_expired')" in vm,
        "auth-failed 映射到登录失效文案（不是「连接丢失」）")

    print("[C] 幂等键生命周期")
    chk("idemKeyForSend" in vm, "存在取键方法")
    chk("fp !== this.sendIdemFp" in vm, "内容变化即换键（防同键不同载荷 409）")
    i_create = vm.find("this.runs.createRun(input, this.activeSessionId, idemKey)")
    i_clear = vm.find("this.sendIdemKey = ''", i_create if i_create != -1 else 0)
    chk(i_create != -1, "发送时把键传给 createRun")
    chk(i_create != -1 and i_clear != -1 and i_clear > i_create,
        "受理后清键（下次发送重新起键）")

    print("[D] 审批窗口按服务端口径（2026-11-26）")
    run_model = read(ETS / "model/Run.ets")
    chk("timeout_sec" in run_model, "ApprovalControl 带 timeout_sec 字段")
    chk("numFrom(d['timeout_s'])" in run_model, "两个解析点都取 timeout_s")
    chk("APPROVAL_TIMEOUT_FALLBACK_SEC" in vm, "客户端窗口有兜底常量")
    # 兜底值必须是实测出来的 60s（run_c14b9bea…，t=60s 自动拒绝），不是拍脑袋的常量。
    chk(re.search(r"APPROVAL_TIMEOUT_FALLBACK_SEC: number = 60\b", vm) is not None,
        "兜底窗口 = 60s（实测值）")
    chk("timeout_s" in vm and "run_c14b9bea" in vm, "注释里留下实测证据（防后人再猜）")
    chk("req.timeout_sec > 0" in vm, "setPendingApproval 优先用服务端 timeout_s")
    i_resume = vm.find("resumeFromBackground(): void")
    tail = vm[i_resume:i_resume + 900] if i_resume != -1 else ""
    chk("this.approvalPollTick()" in tail, "回前台立刻对账审批（不等 5s 拍点）")
    chk("this.baselinePollTick(this.activeRunId)" in tail, "回前台立刻补一拍 run 状态")
    import json as _json
    ok_keys = True
    for loc in ("base", "zh_CN", "en_US"):
        try:
            d = _json.loads((ROOT / "entry/src/main/resources" / loc / "element/string.json").read_text(encoding="utf-8"))
            if not any(x["name"] == "approval_countdown_over" for x in d["string"]):
                ok_keys = False
        except Exception:
            ok_keys = False
    chk(ok_keys, "三套资源都有 approval_countdown_over（倒计时归零不说「已过期」）")

    print()
    if failures:
        print(f"RESILIENCE_SELFTEST: FAIL（{len(failures)}/{checks} 项）")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"RESILIENCE_SELFTEST: PASS（{checks} 项）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
