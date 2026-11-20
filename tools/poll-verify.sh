#!/usr/bin/env bash
# tools/poll-verify.sh —— 轮询一键回归（需要真机 + 可达的 Hermes 网关）
#
# 做一件事：发一条会长回答的消息 → 抓 N 秒 hilog → 校验自适应拍距曲线。
# 断言的是「行为」，不是「代码长什么样」：
#   · 起跑 2000ms
#   · 前三拍实测间隔 ≈ 2000ms
#   · 出现 slowed down: interval=4000ms
#   · 出现 slowed down: interval=5000ms（上限封顶）
#   · 总拍数 ≥ 7
#
# 用法：
#   HDC="/path/to/hdc.exe" TARGET=<ip:port> bash tools/poll-verify.sh
#   可选：PROMPT="..."  SECONDS=28  SKIP_LAUNCH=1
#
# 前置：App 已装、网关可达、屏幕已解锁。脚本会重启 App 并清掉当前会话视图，
#       不会删除任何会话数据。
#
# 退出码：0 = 全部通过；1 = 有断言失败；2 = 环境问题（设备不可达等）。
set -euo pipefail

HDC="${HDC:-hdc}"
TARGET="${TARGET:-}"
PROMPT="${PROMPT:-count slowly from 1 to 500, one per line, no commentary}"
SECONDS_TO_WATCH="${SECONDS_TO_WATCH:-28}"
BUNDLE="${BUNDLE:-com.pzmmy.hermespaw}"
# 输入框坐标（RS 80 / 1440x3200 实测）；换设备时可用 INPUT_XY 覆盖。
INPUT_XY="${INPUT_XY:-538 2444}"
LOG="${LOG:-/tmp/paw-poll-verify-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*"; }
die() { say "❌ $*"; exit 2; }

[ -n "$TARGET" ] || die "未指定 TARGET=<ip:port>（先 hdc list targets 看）"
say "设备：$TARGET   日志：$LOG"

"$HDC" -t "$TARGET" shell "echo ok" >/dev/null 2>&1 || die "设备不可达：$TARGET"

# 清空旧日志，避免上一轮拍点混进来
: > "$LOG"

if [ "${SKIP_LAUNCH:-0}" != "1" ]; then
  say "→ 重启 App"
  "$HDC" -t "$TARGET" shell power-shell wakeup >/dev/null 2>&1 || true
  "$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  "$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a EntryAbility >/dev/null 2>&1 || true
  sleep 7
fi

# 从当前界面找「发送 / Send」按钮坐标（键盘是否弹起会改变位置，所以现查）
find_send_xy() {
  "$HDC" -t "$TARGET" shell uitest dumpLayout >/dev/null 2>&1 || return 1
  local f
  f=$("$HDC" -t "$TARGET" shell "ls -t /data/local/tmp/ | grep -a '^layout_' | head -1" | tr -d '\r\n')
  [ -n "$f" ] || return 1
  "$HDC" -t "$TARGET" shell "cat /data/local/tmp/$f" 2>/dev/null | python3 -c '
import json,sys,re
raw=sys.stdin.read()
i=raw.find("{")
if i<0: sys.exit(1)
try: d=json.loads(raw[i:])
except Exception: sys.exit(1)
hits=[]
def w(n):
    if isinstance(n,dict):
        a=n.get("attributes") if isinstance(n.get("attributes"),dict) else {}
        t=(a.get("text") or "").strip(); b=a.get("bounds") or ""
        m=[int(x) for x in re.findall(r"-?\d+", b)] if b else []
        if t in ("发送","Send") and len(m)==4:
            hits.append(((m[0]+m[2])//2,(m[1]+m[3])//2))
        for v in n.values(): w(v)
    elif isinstance(n,list):
        for v in n: w(v)
w(d)
print(f"{hits[-1][0]} {hits[-1][1]}" if hits else "")
' || return 1
}

say "→ 输入探针消息"
read -r IX IY <<<"$INPUT_XY"
"$HDC" -t "$TARGET" shell uitest uiInput click "$IX" "$IY" >/dev/null 2>&1 || true
sleep 2
"$HDC" -t "$TARGET" shell uitest uiInput inputText "$IX" "$IY" "$PROMPT" >/dev/null 2>&1 || true
sleep 2
# 软键盘弹起时 dumpLayout 只返回键盘窗口（实测坑），先点消息区收起再找按钮。
"$HDC" -t "$TARGET" shell uitest uiInput click "$IX" 1200 >/dev/null 2>&1 || true
sleep 2

SEND=""
for _ in 1 2 3; do
  SEND=$(find_send_xy || true)
  [ -n "${SEND:-}" ] && break
  sleep 2
done
if [ -z "${SEND:-}" ]; then
  say "⚠ 界面里没找到「发送」，退回默认坐标"
  SEND="1172 1631"
fi
say "→ 点发送 @ $SEND"
read -r SX SY <<<"$SEND"
"$HDC" -t "$TARGET" shell uitest uiInput click "$SX" "$SY" >/dev/null 2>&1 || true

say "→ 抓 ${SECONDS_TO_WATCH}s hilog"
timeout "$SECONDS_TO_WATCH" "$HDC" -t "$TARGET" shell hilog > "$LOG" 2>&1 || true

say "→ 校验"
python3 - "$LOG" <<'PY'
import re, sys
log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
fails = []

def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (("  [" + detail + "]") if detail else ""))
    if not cond:
        fails.append(name)

# 日志里可能有多次 run（重发/插话/上一轮残留），必须按 run 分段：
# 每段从 "baseline poll started" 开始，到下一条 started 之前结束。只校验第一段。
segments = re.split(r"(?=baseline poll started:)", log)
runs = [seg for seg in segments if "baseline poll started:" in seg]
check("轮询已起跑（baseline poll started）", len(runs) > 0)
if not runs:
    print("\nRESULT: FAILED —— 没有拍到轮询日志。常见原因：消息没发出去（坐标不对）、"
          "网关不可达、或 App 未启动。")
    sys.exit(1)
if len(runs) > 1:
    print(f"  note 日志里有 {len(runs)} 次 run，只校验第一次（其余可能是重发/插话）")

seg = runs[0]
start = re.search(r"interval=(\d+)ms", seg)
base = int(start.group(1))
check("起跑拍距 = 2000ms", base == 2000, str(base) + "ms")

ts = [int(x) for x in re.findall(r"ChatVM: poll#\d+ t=(\d+)ms", seg)]
check("单次 run 拍到 ≥7 个拍点", len(ts) >= 7, str(len(ts)))

gaps = [ts[i] - ts[i - 1] for i in range(1, len(ts))]
# 策略是「连续 3 次无变化才翻倍」，所以在每个拍距上只会看到 2 个间隔就进下一档：
#   2s x3 拍 -> 2 个 ~2000ms 间隔 -> 4s x3 拍 -> 2 个 ~4000ms -> 5s 封顶
check("起跑段 2 个间隔 ≈ 2000ms", len(gaps) >= 2 and all(1800 <= g <= 2600 for g in gaps[:2]),
      str(gaps[:2]))
check("出现过降频到 4000ms", "slowed down: interval=4000ms" in log)
check("出现过降频到 5000ms（封顶）", "slowed down: interval=5000ms" in log)

if len(gaps) >= 5:
    mid = gaps[2:4]
    check("降频段 2 个间隔 ≈ 4000ms", all(3500 <= g <= 4600 for g in mid), str(mid))
if len(gaps) >= 6:
    last = gaps[-1]
    check("封顶后间隔 ≈ 5000ms（rearm 真的重建了 ticker）", 4300 <= last <= 5800, str(last))

print("\n拍点：", ", ".join(str(t) + "ms" for t in ts))
print("间隔：", ", ".join(str(g) + "ms" for g in gaps))
if fails:
    print("RESULT: FAILED -> " + ", ".join(fails))
    sys.exit(1)
print("RESULT: ALL GREEN")
PY
rc=$?
[ $rc -eq 0 ] && say "✅ 轮询回归通过（日志 $LOG）" || say "❌ 轮询回归失败（日志 $LOG）"
exit $rc
