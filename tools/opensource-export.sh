#!/usr/bin/env bash
# =====================================================================
# tools/opensource-export.sh — S3-e 开源内容边界导出（D4）
#
# 用 git archive 导出已提交树，然后对导出树跑 s3-selftest.py 秘密扫描
# 验证。全绿才算导出干净。
#
# 排除目录均为「私有 force-add 或内部参考」，不随公开包分发（D4）；
# 其中 docs/test-reports/ 与 docs/opensource-research/ 已跟踪
# （前者 force-add、后者正常提交），须 archive pathspec 显式排除：
#   docs/test-reports/         内部 QA 证据（含内网 IP / 用户名）
#   docs/opensource-research/  第三方参考源码（GPL-3.0）——已于 2026-11-19 移出仓库，排除项保留为双保险
#   evidence/                  内部证据（untracked，天然不在）
#
# GitHub 推送由主控执行（D5：全新干净仓库，不做历史清洗——历史含
# test-reports 的 IP/用户名，filter-repo 成本高且有残留风险）。
#
# 用法: tools/opensource-export.sh [输出目录，默认 /tmp/hermes-paw-opensource]
# 退出码: 0=干净, 1=扫描 FAIL
# =====================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/hermes-paw-opensource}"

command -v git >/dev/null || { echo "需要 git" >&2; exit 2; }
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT"

# 已提交树导出，D4 排除目录经 pathspec 显式排除（test-reports /
# opensource-research 已跟踪，靠 .gitignore 挡不住 git archive）
git -C "$REPO" archive --format=tar HEAD -- . \
    ':(exclude)docs/test-reports' \
    ':(exclude)docs/opensource-research' \
    ':(exclude)evidence' | tar -x -C "$OUT"

# 边界内件存在性抽查
for f in README.md LICENSE docs/server-setup.md tools/hermes-paw-qr tools/s3-selftest.py; do
  [ -f "$OUT/$f" ] || { echo "缺失: $f" >&2; exit 1; }
done

# 排除项不得出现（gitignore 之外的双保险；opensource-research 已跟踪，
# 靠 archive 路径排除，此处再验一道）
for d in evidence docs/test-reports docs/opensource-research; do
  [ -e "$OUT/$d" ] && { echo "排除项泄漏: $d" >&2; exit 1; }
done

# 秘密扫描（对导出树自身）
python3 "$OUT/tools/s3-selftest.py"

echo "OK: 导出 $OUT ($(du -sh "$OUT" | cut -f1), $(find "$OUT" -type f | wc -l) files)"
echo "下一步（主控）: git init + push 到全新公开仓库（D5）"
