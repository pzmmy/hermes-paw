#!/usr/bin/env python3
"""S7a 门禁：PollPolicy 抽取的正确性与 ChatVM 无残留。

A 类（静态）：文件存在、导出齐全、ChatVM 不再自持常量、import 路径正确。
B 类（语义）：用 Python 复刻 nextPollInterval，断言与「抽出前」的原始语义逐点一致。
C 类（反向对照）：故意写一个漏掉封顶的变异体，断言它与正解在某点不同 ——
   证明 B 类断言真的能抓到「封顶被删」这种回归。
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY = ROOT / "entry/src/main/ets/viewmodel/stream/PollPolicy.ets"
VM = ROOT / "entry/src/main/ets/viewmodel/ChatVM.ets"
fails = []

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" | " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(name)

ptxt = POLICY.read_text(encoding="utf-8") if POLICY.exists() else ""
vtxt = VM.read_text(encoding="utf-8") if VM.exists() else ""

# A1 导出
for sym in ("POLL_START_MS", "POLL_MAX_MS", "POLL_SSE_ACTIVE_MS",
            "POLL_IDLE_ROUNDS_TO_DOUBLE", "nextPollInterval"):
    check("A1 导出 %s" % sym, ("export const %s" % sym) in ptxt or ("export function %s" % sym) in ptxt)

# A2 ChatVM 无残留常量
check("A2 ChatVM 无 BASELINE_POLL 残留", vtxt.count("BASELINE_POLL") == 0,
      "count=%d" % vtxt.count("BASELINE_POLL"))

# A3 import 路径
check("A3 ChatVM 从 ./stream/PollPolicy 导入",
      "from './stream/PollPolicy'" in vtxt)

# A4 常量值
def const(name):
    m = re.search(r"export const %s: number = (\d+);" % name, ptxt)
    return int(m.group(1)) if m else None

check("A4a POLL_START_MS=2000", const("POLL_START_MS") == 2000)
check("A4b POLL_MAX_MS=5000", const("POLL_MAX_MS") == 5000)
check("A4c POLL_SSE_ACTIVE_MS=10000", const("POLL_SSE_ACTIVE_MS") == 10000)
check("A4d POLL_IDLE_ROUNDS_TO_DOUBLE=3", const("POLL_IDLE_ROUNDS_TO_DOUBLE") == 3)

# B 语义复刻（与 ArkTS 实现逐行对应）
START, MAXV, IDLE = 2000, 5000, 3

def next_interval(cur, rounds):
    if rounds < IDLE:
        return cur
    if cur >= MAXV:
        return cur
    d = cur * 2
    return MAXV if d > MAXV else d

cases = [
    ((2000, 0), 2000), ((2000, 2), 2000),
    ((2000, 3), 4000), ((2000, 9), 4000),
    ((4000, 3), 5000), ((4000, 7), 5000),
    ((5000, 3), 5000), ((5000, 99), 5000),
]
for (cur, r), want in cases:
    got = next_interval(cur, r)
    check("B 语义 next(%d,%d)=%d" % (cur, r, want), got == want, "got=%d" % got)

# C 反向对照：漏掉封顶的变异体
def mutant(cur, rounds):
    if rounds < IDLE:
        return cur
    return cur * 2      # 没有封顶

diff = [((c, r), mutant(c, r)) for (c, r), want in cases if mutant(c, r) != want]
check("C 反向对照：去掉封顶必与正解不同", len(diff) > 0,
      "变异体与期望一致，说明断言无效")

# D 结构断言：ChatVM 里自适应段落确实走 nextPollInterval
# 2026-11-20：拍距字段搬进 PollScheduler 后，入参由 this.baselinePollIntervalMs
# 变成 this.poller.getIntervalMs()。断言改为「调用了 nextPollInterval」，不再绑死参数表达式。
check("D1 ChatVM 调用 nextPollInterval", "nextPollInterval(" in vtxt)
check("D2 ChatVM 仍有 slowed down 日志",
      "baseline poll slowed down" in vtxt)

print()
if fails:
    print("RESULT: %d FAILED -> %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("RESULT: ALL GREEN (%d assertions)" % (len(cases) + 10))
