#!/usr/bin/env bash
# tools/ohostest.sh — 跑 ohosTest（hypium，真机/模拟器）
#
# 前置：
#   1) 已用 DevEco 或 build-ohostest 流程产出两个 HAP：
#        主包 entry/build/default/outputs/default/entry-default-signed.hap
#        测试包 entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap
#   2) 设备已连上 hdc
#
# 用法：
#   HDC="<hdc 可执行>" TARGET=127.0.0.1:5555 bash tools/ohostest.sh
#   （Windows 调 WSL：HDC 用 /mnt/d/.../hdc.exe，TARGET 用 <ip>:<port>）
#
# 说明：为什么不直接用 `hvigorw ... test`
#   该任务在本地 DevEco 6.26.8 上会卡在 18 个构建任务之后不动（不报错、不退出），
#   所以改成「assembleHap → hdc install → aa test」三步，结果可判定、日志可留存。
set -uo pipefail

HDC=${HDC:-hdc}
TARGET=${TARGET:-127.0.0.1:5555}
BUNDLE=com.pzmmy.hermespaw
TEST_MODULE=entry_test
RUNNER=OpenHarmonyTestRunner
OUT=${OUT:-/tmp/paw-ohostest}
mkdir -p "$OUT"
LOG="$OUT/result.log"

echo "[1/3] 装主包与测试包"
"$HDC" -t "$TARGET" install -r entry/build/default/outputs/default/entry-default-signed.hap 2>&1 | tr -d '\r' | tail -2
"$HDC" -t "$TARGET" install -r entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap 2>&1 | tr -d '\r' | tail -2

echo "[2/3] aa test"
timeout 300 "$HDC" -t "$TARGET" shell aa test -b "$BUNDLE" -m "$TEST_MODULE" \
  -s unittest "$RUNNER" -s timeout 180000 > "$LOG" 2>&1
rc=$?
echo "    aa test rc=$rc  (日志: $LOG)"

echo "[3/3] 结果"
python3 - "$LOG" <<'PY'
import re,sys
raw=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'Tests run:\s*(\d+),\s*Failure:\s*(\d+),\s*Error:\s*(\d+),\s*Pass:\s*(\d+)', raw)
if m:
    run,fail,err,ok=[int(x) for x in m.groups()]
    print(f"    Tests run: {run}  Pass: {ok}  Failure: {fail}  Error: {err}")
    print("    VERDICT:", "OK" if fail==0 and err==0 and run==ok else "FAIL")
    raise SystemExit(0 if fail==0 and err==0 and run==ok else 1)
print("    日志里没有 Tests run 汇总行 —— 判定为未跑通（不要当成绿）")
print("    末 6 行：")
for l in raw.splitlines()[-6:]:
    print("     ", l[:160])
raise SystemExit(2)
PY
