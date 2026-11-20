#!/usr/bin/env python3
"""PollScheduler 门禁：静态结构 + 状态机镜像。

A 类（静态）——防回归：调度器该有的东西在、ChatVM 不该再自己管定时器。
B 类（语义）——用 Python 复刻 PollScheduler 的四条不变量，用假时钟跑断言：
  1. 同一时刻只有一条 ticker
  2. 同一 run 在飞 getRun ≤ 1
  3. 拍距可换，但只在运行中生效
  4. stop() 之后状态全归零，且可再次 start

说明：B 类验的是「策略语义」，不是 ArkTS 代码本身（Python 跑不了 ArkTS）。
真正的端到端证据在 tools/poll-verify.sh（需要真机）。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / "entry/src/main/ets"
SCHED = ETS / "viewmodel/PollScheduler.ets"
VM = ETS / "viewmodel/ChatVM.ets"

fails = []


def check(name, cond, detail=""):
    if cond:
        print("  ok   " + name)
    else:
        print("  FAIL " + name + (("  [" + detail + "]") if detail else ""))
        fails.append(name)


def src(p):
    return p.read_text(encoding="utf-8") if p.exists() else ""


print("== A. static structure ==")
sched = src(SCHED)
check("PollScheduler.ets exists", SCHED.exists(), str(SCHED))
check("exports class PollScheduler", re.search(r"export\s+class\s+PollScheduler", sched) is not None)
for m in ("start", "rearm", "stop", "tryEnter", "leave", "isRunning",
          "getRunId", "getIntervalMs", "getStartAt", "getElapsedSec"):
    check("has " + m + "()", re.search(r"\b" + m + r"\s*\(", sched) is not None)

# start() 必须先 stop()：保证「同一时刻只有一条 ticker」
start_body = sched[sched.index("start("):] if "start(" in sched else ""
check("start() clears previous state first",
      re.search(r"start\([^)]*\)[^{]*\{\s*this\.stop\(\)", sched) is not None)

# rearm 的两个守卫
check("rearm() no-ops when not running",
      re.search(r"rearm\([^)]*\)[^{]*\{[\s\S]{0,200}tickerId\s*===\s*-1", sched) is not None)
check("rearm() no-ops when interval unchanged",
      re.search(r"rearm\([^)]*\)[^{]*\{[\s\S]{0,300}intervalMs\s*===\s*this\.intervalMs", sched) is not None)

# stop 归零
stop_ok = all(re.search(p, sched) is not None for p in (
    r"inFlight\s*=\s*false", r"runId\s*=\s*''", r"startAt\s*=\s*0", r"elapsed\s*=\s*0"))
check("stop() zeroes inFlight/runId/startAt/elapsed", stop_ok)

print("== A2. ChatVM no longer owns the mechanism ==")
vm = src(VM)
check("ChatVM imports PollScheduler", "from './PollScheduler'" in vm)
for banned in ("baselinePollTimer", "baselinePollInFlight", "baselinePollIntervalMs",
               "baselineRunId", "baselineStartAt", "armBaselineTicker"):
    check("ChatVM has no " + banned, banned not in vm)
check("ChatVM drives ticks through poller", "this.poller.tryEnter()" in vm
      and "this.poller.leave()" in vm)
check("ChatVM changes cadence through poller", "this.poller.rearm(" in vm)

print("== B. state-machine mirror (fake clock) ==")


class FakeClock:
    """最小 setInterval 镜像：手动推进时间，按到期顺序派发，派发后自动重排。"""

    def __init__(self):
        self.now = 0
        self.timers = {}
        self._next_id = 1000

    def set_interval(self, fn, ms):
        tid = self._next_id
        self._next_id += 1
        self.timers[tid] = [ms, self.now + ms, fn]  # [period, next_fire, fn]
        return tid

    def clear_interval(self, tid):
        self.timers.pop(tid, None)

    def advance(self, ms):
        end = self.now + ms
        while True:
            due = sorted((t[1], tid) for tid, t in self.timers.items() if t[1] <= end)
            if not due:
                break
            fire_at, tid = due[0]
            self.now = fire_at
            t = self.timers.get(tid)
            if t is None:          # 回调里被 clear 掉
                continue
            t[1] = self.now + t[0]  # 重排下一次
            t[2]()
        self.now = end


class SchedulerMirror:
    """PollScheduler 的语义镜像：与 .ets 一一对应（见 docs/impl-status.md §2.22）。"""

    def __init__(self, clock):
        self.c = clock
        self.ticker = None
        self.elapsed = None
        self.in_flight = False
        self.interval = 0
        self.run_id = ""
        self.start_at = 0
        self.secs = 0
        self.ticks = []

    def start(self, rid, interval_ms):
        self.stop()
        self.run_id = rid
        self.interval = interval_ms
        self.start_at = self.c.now
        self.secs = 0
        self.ticker = self.c.set_interval(lambda: self.ticks.append(self.run_id), interval_ms)
        self.elapsed = self.c.set_interval(lambda: setattr(self, "secs", self.secs + 1), 1000)

    def rearm(self, interval_ms):
        if self.ticker is None:
            return
        if interval_ms == self.interval:
            return
        self.interval = interval_ms
        if self.ticker is not None:
            self.c.clear_interval(self.ticker)
        self.ticker = self.c.set_interval(lambda: self.ticks.append(self.run_id), interval_ms)

    def stop(self):
        if self.ticker is not None:
            self.c.clear_interval(self.ticker)
            self.ticker = None
        if self.elapsed is not None:
            self.c.clear_interval(self.elapsed)
            self.elapsed = None
        self.in_flight = False
        self.run_id = ""
        self.start_at = 0
        self.secs = 0

    def try_enter(self):
        if self.in_flight:
            return False
        self.in_flight = True
        return True

    def leave(self):
        self.in_flight = False


c = FakeClock()
s = SchedulerMirror(c)
s.start("run_a", 2000)
check("start arms exactly 2 timers (ticker + clock)", len(c.timers) == 2, str(len(c.timers)))
check("start records run identity", s.run_id == "run_a" and s.start_at == 0)

c.advance(6000)
check("2000ms cadence -> 3 ticks in 6s", len(s.ticks) == 3, str(len(s.ticks)))
check("elapsed counter tracks seconds", s.secs == 6, str(s.secs))

check("first try_enter succeeds", s.try_enter() is True)
check("second try_enter blocked (<=1 in flight)", s.try_enter() is False)
s.leave()
check("try_enter allowed after leave", s.try_enter() is True)
s.leave()

s.ticks = []
s.rearm(4000)
c.advance(8000)
check("rearm to 4000ms -> 2 ticks in 8s", len(s.ticks) == 2, str(len(s.ticks)))
check("rearm keeps a single ticker", len(c.timers) == 2, str(len(c.timers)))

before = len(s.ticks)
s.rearm(4000)  # 同值
c.advance(4000)
check("rearm(same) does not double-arm",
      len(s.ticks) == before + 1 and len(c.timers) == 2)

s.stop()
check("stop clears all timers", len(c.timers) == 0, str(len(c.timers)))
check("stop zeroes identity and flags",
      s.run_id == "" and s.start_at == 0 and s.secs == 0 and s.in_flight is False)

s.ticks = []
c.advance(10000)
check("no ticks after stop", len(s.ticks) == 0)
s.stop()
check("stop is idempotent", len(c.timers) == 0)

s.rearm(5000)
check("rearm while stopped is a no-op", len(c.timers) == 0 and s.interval == 4000,
      str(s.interval))

s.start("run_b", 2000)
c.advance(2000)
check("restart after stop works", len(s.ticks) == 1 and s.run_id == "run_b")

print()
if fails:
    print("RESULT: %d FAILED -> %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("RESULT: ALL GREEN")
