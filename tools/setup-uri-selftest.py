#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P0-1 gate: SetupUri `a` 参数解码自测（2026-11-18 真机实测缺陷的固化门）。

背景（docs/test-reports/real-device-baseline.md §1①）：
  服务端脚本按标准把冒号编码成 %3A，而 parseSetupUri 的四个参数里只有 `a`
  没有 pctDecode -> aVal 变成 "192.0.2.10%3A8377" -> 探活 100% 失败。

两部分：
  1. 源码断言（防回退）：`k === 'a'` 分支必须出现 pctDecode(；且 split(',') 之后
     仍存在对 host 的 pctDecode（兼容"整串未编码、单个 host 被编码"的历史串）。
  2. 语义镜像：用 Python 重写一份等价解析，跑 4 个用例并断言结果。

零依赖（仅 stdlib）；repo 根 = 本文件父目录；失败退出码 1。
"""
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / "entry" / "src" / "main" / "ets" / "model" / "SetupUri.ets"

PASS = 0
FAIL = 0


def check(ok: bool, label: str, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  ok   {label}")
    else:
        FAIL += 1
        print(f"  FAIL {label}" + (f"  [{detail}]" if detail else ""))


# ---------- 1. 源码断言 ----------

def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("//"))


def source_checks() -> None:
    print("[src] 源码断言（防回退）")
    if not ETS.exists():
        check(False, f"{ETS} 存在", "缺文件")
        return
    code = strip_comments(ETS.read_text(encoding="utf-8"))

    # a 分支：if/else-if 条件 k === 'a' 起，到下一个分支/花括号收尾。
    m = re.search(r"k === 'a'\s*\)\s*\{(.*?)\n\s*\}", code, flags=re.S)
    check(m is not None, "找到 k === 'a' 分支")
    if m is not None:
        body = m.group(1)
        check("pctDecode(" in body,
              "k === 'a' 分支内出现 pctDecode(",
              body.strip()[:80])
        # 不允许仍然是裸赋值
        check(not re.search(r"aVal\s*=\s*v\s*;", body),
              "k === 'a' 分支不再把 v 裸赋给 aVal")

    # split(',') 之后对 host 的兜底解码
    sp = code.find("split(',')")
    check(sp >= 0, "找到 aVal.split(',')")
    if sp >= 0:
        tail = code[sp:]
        # 只看 for 循环体那一段（到 push 收口）
        end = tail.find("hosts.push")
        seg = tail[:end + 200] if end >= 0 else tail[:400]
        check("pctDecode(" in seg,
              "split(',') 之后对 host 调用 pctDecode（兜底解码）",
              seg.strip().replace("\n", " ")[:120])


# ---------- 2. 语义镜像 ----------

def pct_decode(v: str) -> str:
    """镜像 ArkTS pctDecode：无 '%' 原样返回；UTF-8 解码。"""
    if "%" not in v:
        return v
    return unquote(v, encoding="utf-8", errors="replace")


def parse_mirror(raw: str) -> dict:
    """镜像 parseSetupUri 的关键路径（只覆盖本任务断言所需字段）。"""
    out = {"name": "", "hosts": [], "key": "", "pf": "", "t": "", "error": ""}
    s = raw.strip()
    if not s.startswith("hermespaw://"):
        out["error"] = "scheme"
        return out
    rest = s[len("hermespaw://"):]
    q = rest.find("?")
    path = rest[:q] if q >= 0 else rest
    query = rest[q + 1:] if q >= 0 else ""
    if not path.startswith("setup/"):
        out["error"] = "path"
        return out
    if path[len("setup/"):] != "1":
        out["error"] = "version"
        return out

    name = a_val = key = pf = t = ""
    seen = []
    for kv in query.split("&"):
        if kv == "":
            continue
        eq = kv.find("=")
        if eq <= 0:
            continue
        k = kv[:eq]
        if k in seen:
            continue  # first occurrence wins
        seen.append(k)
        v = kv[eq + 1:]
        if k == "n":
            name = pct_decode(v)
        elif k == "a":
            a_val = pct_decode(v)          # P0-1 主修
        elif k == "k":
            key = pct_decode(v)
        elif k == "pf":
            pf = pct_decode(v)
        elif k == "t":
            t = v
    if name == "":
        out["error"] = "missing n"
        return out
    if a_val == "":
        out["error"] = "missing a"
        return out
    if t != "lan":
        out["error"] = "bad t"
        return out

    hosts = []
    for h in a_val.split(","):
        h = pct_decode(h.strip())          # P0-1 兜底
        if h != "" and h not in hosts:
            hosts.append(h)
    if not hosts:
        out["error"] = "empty a"
        return out
    if pf == "default":
        pf = ""
    out["name"] = name
    out["hosts"] = hosts
    out["key"] = key
    out["pf"] = pf
    out["t"] = t
    return out


def uri(name: str, a: str, t: str = "lan", pf: str = "default") -> str:
    return f"hermespaw://setup/1?n={name}&a={a}&k=s3cr3t&pf={pf}&t={t}"


def semantic_checks() -> None:
    print("[sem] 语义镜像（4 用例）")

    # 1. 整串编码（服务端脚本的真实输出形态）
    r = parse_mirror(uri("%E5%AE%88%E9%97%A8%E4%BA%BA", "192.0.2.10%3A8377"))
    check(r["hosts"] == ["192.0.2.10:8377"], "1. a=%3A 编码 -> host 还原冒号",
          str(r["hosts"]))

    # 2. 未编码
    r = parse_mirror(uri("%E5%AE%88%E9%97%A8%E4%BA%BA", "192.0.2.10:8377"))
    check(r["hosts"] == ["192.0.2.10:8377"], "2. a 未编码 -> 同样得到 host",
          str(r["hosts"]))

    # 3. 多 host + 去重
    r = parse_mirror(uri("%E5%AE%88%E9%97%A8%E4%BA%BA",
                         "192.0.2.10%3A8377,192.0.2.11%3A8377,192.0.2.10%3A8377"))
    check(r["hosts"] == ["192.0.2.10:8377", "192.0.2.11:8377"],
          "3. 多 host 编码 -> 两个 host 且去重", str(r["hosts"]))

    # 4. n 含中文 + pf=default 归一为空串
    r = parse_mirror(uri("%E5%AE%88%E9%97%A8%E4%BA%BA", "192.0.2.10%3A8377"))
    check(r["name"] == "守门人", "4a. n 中文解码正确", r["name"])
    check(r["pf"] == "", "4b. pf=default 归一为空串（保持现有行为）", repr(r["pf"]))
    check(r["error"] == "", "4c. 整串无解析错误", r["error"])

    # 4 个主用例 = 3 条 host 断言 + 用例 4 的组合；按任务口径打印 4/4。
    print("  → 4/4 通过" if FAIL == 0 else f"  → {FAIL} 条失败")


def main() -> int:
    print("=== SetupUri `a` 解码自测（P0-1）===")
    source_checks()
    semantic_checks()
    print(f"SETUP_URI_SELFTEST: {'PASS' if FAIL == 0 else 'FAIL'} "
          f"(checks {PASS} ok / {FAIL} failed)")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())