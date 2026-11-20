#!/usr/bin/env python3
"""L2 gate: S1.5 self-test — prompt template sync + P0 script-behavior regression.

P1-A3 (170 审爷 第1轮签发, 2026-11-15): "改一处必同步"（OnboardPrompt.ets ↔
脚本 --prompt）此前无任何自动化承载——236 的 4/4 比对是一次性 scratch，随提交
消失，下次漂移无人知。本工具固化为 L2 门（每次 L2 必跑），机械提取 .ets 函数体
字面量（注释剥离）重建提示词，与脚本 --prompt 输出字节级比对
（v2.6.6 单一档目标式模板，3 案例：未指定名/指定名/名含引号）。

P0-1 regression: --json 与 --png 互斥（§4.8 D1 stdout 零 URI 契约）——防组合
静默泄漏 key 到 agent terminal 日志的回归（agent 把两条命令合成一跑是最自然
偷懒路径）。

零依赖（仅 stdlib）。相对路径（repo 根 = 本文件父目录），任意 checkout 可跑。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / "entry" / "src" / "main" / "ets" / "util" / "OnboardPrompt.ets"
QR = ROOT / "tools" / "hermes-paw-qr"


def extract_literals(path: Path):
    """注释剥离后提取 .ets 函数体全部单引号字符串字面量（保持顺序）。"""
    src = path.read_text(encoding="utf-8")
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("//"))
    return re.findall(r"'((?:[^'\\]|\\.)*)'", src)


def check_sync() -> int:
    """P1-A3: OnboardPrompt.ets 字面量 ↔ 脚本 --prompt 字节级一致（v2.6.6 目标式模板，3 案例：未指定名/指定名/名含引号）。"""
    if not ETS.exists():
        print(f"[sync] FAIL: {ETS} 不存在（需完整仓库 checkout；送审包必须包含 OnboardPrompt.ets，P0-r2-1 事实②）")
        return 1
    lits = extract_literals(ETS)
    # 期望 11 个字面量（注释剥离后的函数体，v2.6.6 目标式模板，按源码顺序）：
    #  0 标题行  1 ''(name 空测)  2,3 档案名行切段  4..9 目标项 1..6
    #  10 join 分隔符 '\n'
    if len(lits) != 11:
        print(f"[sync] FAIL: 期望 11 字面量，实得 {len(lits)}")
        for i, l in enumerate(lits):
            print(f"    [{i}] {l[:50]!r}")
        return 1
    if lits[1] != "" or lits[10] != "\\n":
        print(f"[sync] FAIL: 空测/join 字面量异常: {lits[1]!r} / {lits[10]!r}")
        return 1

    def build(name: str) -> str:
        out = [lits[0]]
        if name:
            out.append(lits[2] + name + lits[3])
        out.extend(lits[4:10])
        return "\n".join(out)

    rc = 0
    for name in ("", "张三", "A'B" + '"C'):
        args = [sys.executable, str(QR), "--prompt"]
        if name:
            args += ["--name", name]
        expected = subprocess.run(args, capture_output=True, text=True).stdout
        if expected.endswith("\n"):  # 脚本 print 带行尾换行，模板本体无
            expected = expected[:-1]
        got = build(name)
        if expected != got:
            rc = 1
            print(f"[sync] FAIL name={name or '(未指定)'}")
            for i, (a, b) in enumerate(zip(expected.splitlines(), got.splitlines())):
                if a != b:
                    print(f"    行 {i+1} 差异:")
                    print(f"      script: {a!r}")
                    print(f"      ets   : {b!r}")
            if len(expected) != len(got):
                print(f"    长度: script={len(expected)} ets={len(got)}")
        else:
            print(f"[sync] OK   name={name or '(未指定)'}")
    return rc


def check_p0_mutex() -> int:
    """P0-1 regression: --json 与 --png 必须互斥（stdout 零 URI 契约）。P1-r2-1：显式校验 rc==1。P1-r4-4b：'互斥'断言在 stderr 通道（die() 输出通道）。"""
    r = subprocess.run(
        [sys.executable, str(QR), "--json", "--png", "/tmp/s15-p0-mutex.png"],
        capture_output=True, text=True, stdin=subprocess.DEVNULL,
    )
    # P1-r4-4b (2026-11-16 170 审爷 Round 4)：断言只查 stderr——die() 的拒绝输出
    # 走 stderr，且未来 stdout 契约若收紧到 0 字节断言仍成立（不依赖拼接串）。
    if r.returncode == 1 and "互斥" in r.stderr:
        print("[p0] OK   --json --png 组合被 fail-closed 拒绝(rc=1, 提示含'互斥', stdout 零 URI 契约守住)")
        return 0
    print(f"[p0] FAIL: rc={r.returncode}（期望 rc=1 且提示含'互斥'）")
    print(f"  stdout: {r.stdout.strip()[:120]!r}")
    return 1


def main() -> int:
    print("=== S1.5 self-test (P1-A3 模板同步 + P0-1 脚本行为回归) ===")
    rc = 0
    rc |= check_sync()
    rc |= check_p0_mutex()
    print("S15_SELFTEST:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
