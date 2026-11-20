#!/bin/bash
# e2e-emu.sh — 模拟器端到端回归：装包 → 发一条 ASCII 消息 → 抓 hilog 时间线
#
# 为什么要 dump 再点：软键盘弹出后输入框/发送按钮会整体上移（真机上移过 810px），
# 盲点键盘弹出前的坐标会点空。历史踩坑见 docs/impl-status.md §2.3。
#
# 用法：
#   tools/e2e-emu.sh              # 默认消息 "e2e ok"
#   tools/e2e-emu.sh "hello"      # 自定义 ASCII 消息（模拟器中文输入有原生 bug）
#
# 退出码：0 = 抓到 run created + finalize；1 = 没抓到（脚本会先说清抓到哪一步）
#
# 环境：需要 hdc（DevEco toolchain）、已启动的模拟器、已构建的 hap。ASCII/路径均可覆盖：
#   HDC=... TARGET=... HAP=... tools/e2e-emu.sh
set -uo pipefail

HDC=${HDC:-"/mnt/d/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"}
TARGET=${TARGET:-127.0.0.1:5555}
HAP=${HAP:-'C:\Users\12442\WorkBuddy\2026-11-15-19-24-25\hermes-paw\entry\build\default\outputs\default\entry-default-signed.hap'}
BUNDLE=com.pzmmy.hermespaw
MSG=${1:-e2e ok}
WIN=${WIN:-/mnt/c/Users/12442}
OUT=${OUT:-/tmp/paw-e2e}
CAPTURE_S=${CAPTURE_S:-95}

mkdir -p "$OUT"

dump() {  # $1=tag -> 打印本地 json 路径
  "$HDC" -t "$TARGET" shell uitest dumpLayout >/dev/null 2>&1
  local f
  f=$("$HDC" -t "$TARGET" shell ls -t /data/local/tmp/ 2>/dev/null | grep -a layout_ | head -1 | tr -d '\r')
  "$HDC" -t "$TARGET" file recv "/data/local/tmp/$f" "C:\\Users\\12442\\e2e-$1.json" >/dev/null 2>&1
  echo "$WIN/e2e-$1.json"
}

coords() {  # $1=json -> "inX inY sendX sendY" 或 MISS
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8', errors='replace'))
res = {}
def ctr(b):
    try:
        x1, y1, x2, y2 = [int(v) for v in b.replace('][', ',').replace('[', '').replace(']', '').split(',')]
        return (x1 + x2) // 2, (y1 + y2) // 2
    except Exception:
        return None
def walk(n):
    a = n.get('attributes', {})
    t = (a.get('text') or a.get('hint') or '').strip()
    typ = a.get('type', '')
    if typ == 'TextInput' and 'i' not in res:
        p = ctr(a.get('bounds', ''))
        if p: res['i'] = p
    if typ == 'Button' and t == '发送' and 's' not in res:
        p = ctr(a.get('bounds', ''))
        if p: res['s'] = p
    for ch in n.get('children', []):
        walk(ch)
walk(d)
i, s = res.get('i'), res.get('s')
print('%d %d %d %d' % (i[0], i[1], s[0], s[1]) if i and s else 'MISS')
PY
}

has_run() { grep -qiE 'run created' "$1" 2>/dev/null; }

echo "== 安装并启动 =="
timeout 30 "$HDC" -t "$TARGET" shell power-shell wakeup >/dev/null 2>&1
# 安装结果必须断言：历史上出现过静默失败（路径写错 → 装的是旧包），
# 后续日志一切"正常"，极易被当成新包的证据。失败就整轮中止。
# 成功形态在 Windows hdc 下是 `AppMod finish`（不含 success 字样）。
INST=$("$HDC" -t "$TARGET" install -r "$HAP" 2>&1 | tail -1)
echo "$INST"
case "$INST" in
  *"[F]"*|*error*|*"no such file"*|*"Device not found"*|*"INSTALL_FAILED"*)
    echo "INSTALL FAILED -> 中止（不要用旧包跑验证）"; exit 2 ;;
  *"AppMod finish"*|*success*|*"install bundle successfully"*) : ;;
  *) echo "INSTALL 结果未知 -> 中止: $INST"; exit 3 ;;
esac
"$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1
"$HDC" -t "$TARGET" shell aa start -a EntryAbility -b "$BUNDLE" >/dev/null 2>&1
sleep 6

LOG="$OUT/h.log"
( timeout "$CAPTURE_S" "$HDC" -t "$TARGET" shell hilog > "$LOG" 2>&1 ) &
HP=$!
sleep 3

ok=0
for attempt in 1 2 3; do
  J1=$(dump pre); R1=$(coords "$J1")
  if [ "$R1" = "MISS" ]; then echo "[$attempt] 找不到输入框/发送按钮（屏幕锁了？）"; sleep 3; continue; fi
  read -r IX IY _ _ <<< "$R1"
  "$HDC" -t "$TARGET" shell uitest uiInput click "$IX" "$IY" >/dev/null 2>&1
  sleep 2
  J2=$(dump kb); R2=$(coords "$J2")
  if [ "$R2" = "MISS" ]; then echo "[$attempt] 键盘态取坐标失败"; continue; fi
  read -r IX2 IY2 _ _ <<< "$R2"
  "$HDC" -t "$TARGET" shell uitest uiInput inputText "$IX2" "$IY2" "$MSG" >/dev/null 2>&1
  sleep 2
  # 关键：输入后再 dump 一次，发送按钮在键盘态下的位置才是对的
  J3=$(dump typed); R3=$(coords "$J3")
  if [ "$R3" = "MISS" ]; then echo "[$attempt] 输入后取坐标失败"; continue; fi
  read -r _ _ SX SY <<< "$R3"
  "$HDC" -t "$TARGET" shell uitest uiInput click "$SX" "$SY" >/dev/null 2>&1
  echo "[$attempt] 已点发送 send=$SX,$SY $(date +%H:%M:%S)"
  sleep 6
  if has_run "$LOG"; then ok=1; echo "[$attempt] 已抓到 run created"; break; fi
  echo "[$attempt] 未出现 run created，重试"
done

wait $HP

echo "== 时间线（注意：模拟器日志 domain 为小写 A0ff00，且 tag 不带包名，形如 'A0ff00/ChatVM:'）=="
python3 - "$LOG" <<'PY'
import re, sys
txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
keys = re.compile(r'run created|baseline poll|slowed|finalize|gave up|unknown status|stream error|startRecovery', re.I)
seen = []
for line in txt.splitlines():
    if 'ChatVM:' in line and keys.search(line):
        s = re.sub(r'\s+', ' ', line.strip())
        if s not in seen:
            seen.append(s)
for s in seen:
    print(s[:140])
low = txt.lower()
for k in ('gave up', 'unknown status', 'finalize how'):
    print('%-16s %d' % (k, low.count(k)))
print('VERDICT', 'OK' if 'run created' in low else 'NO-RUN')

# 收口后 24s 仍报 SSE idle timeout 是已知待修项，明确标出来，别让它混进"正常"
fin = re.search(r'(\d\d:\d\d:\d\d\.\d+).*?finalize how=(\w+)', txt)
idle = re.search(r'(\d\d:\d\d:\d\d\.\d+).*?SSE idle timeout', txt)
if fin and idle and idle.group(1) > fin.group(1):
    print('NOTE finalize(%s) 之后仍有 SSE idle timeout(%s) —— 见 docs/impl-status.md §2.3 已知待修'
          % (fin.group(1), idle.group(1)))
PY

[ "$ok" = 1 ] && exit 0 || exit 1
