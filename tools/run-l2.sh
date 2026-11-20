#!/usr/bin/env bash
# L2 gate — single entry point for all L2 self-tests (五件套).
# Usage: bash tools/run-l2.sh   （等价入口: make l2，见 Makefile）
# Runs: arkts-lint, api-selftest, s2-selftest, s2b-selftest (S2-b 长按气泡
#       引用/删除：符号/三语资源/接线 + 引用前缀与按引用删除逻辑镜像),
#       s3-selftest, s15-selftest, slash-selftest (P5 斜杠命令),
#       markdown-selftest (P4⑦ 轻量 Markdown：导出/接线 + 解析器逻辑镜像，
#       含流式半截内容降级保证)
# Exits 0 if no FAIL (SKIP = env-limited, non-failure).
# P0-r2-1 修复（170 审爷 r2）：s15-selftest 此前是孤脚本（无入口引用、未接入 L2 门）；
# 本文件把五件套统一接入一个可复现的 L2 门入口。
# 🟡-r3-2 收口（170 审爷 r3）：gateway 依赖项（api-selftest / s2-selftest）在无
# API_SERVER_KEY 的环境（CI / 170 / 新 checkout）返回 rc=77（SKIP，make 惯例
# untested），本门据此记 SKIP 非 FAIL —— 门在任意环境可复现绿。
# 🟢-r3-3 收口：mktemp 加 EXIT trap（中断不漏临时文件）。
# 🟢 收口（170 审爷收口确认建议，可选项落地）：门跑不写字节码，
# 避免 repo 内残留 __pycache__/*.pyc（如 _vendor/segno 运行时副产物）。
export PYTHONDONTWRITEBYTECODE=1
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"
TOOLS=(arkts-lint.py api-selftest.py s2-selftest.py s2b-selftest.py s3-selftest.py s15-selftest.py slash-selftest.py markdown-selftest.py)
pass=0; fail=0; skip=0
log="$(mktemp)"; trap 'rm -f "$log"' EXIT
echo "=== L2 gate (run-l2.sh) — ${#TOOLS[@]} checks ==="
for t in "${TOOLS[@]}"; do
  name="${t%.py}"
  (cd "$ROOT" && "$PY" "tools/$t") >"$log" 2>&1
  rc=$?
  printf '[L2] %-16s ... ' "$name"
  if [ "$rc" -eq 0 ]; then
    echo "PASS"
    pass=$((pass+1))
  elif [ "$rc" -eq 77 ]; then
    echo "SKIP (env-limited)"
    skip=$((skip+1))
    echo "  | $(tail -1 "$log")"
  else
    echo "FAIL (rc=$rc)"
    fail=$((fail+1))
    echo "  --- output tail ---"
    tail -5 "$log" | sed 's/^/  | /'
  fi
done
echo "=== L2 summary: ${pass} PASS / ${fail} FAIL / ${skip} SKIP (of ${#TOOLS[@]}) ==="
if [ "$fail" -eq 0 ]; then
  echo "L2 GREEN (env-limited 项 SKIP，无 FAIL)"
  exit 0
else
  echo "L2 FAIL"
  exit 1
fi
