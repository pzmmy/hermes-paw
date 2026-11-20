#!/usr/bin/env python3
"""S11 门禁：i18n 覆盖率与"零硬编码中文"。

检查项
  A. resources/{base,zh_CN,en_US}/element/string.json 三套 key 集合完全一致
  B. en_US 的值里不含中文字符（翻译遗漏）
  C. 代码区（注释剥离后）不再出现中文字符串字面量
     —— 白名单：util/OnboardPrompt.ets（引导提示词是发给网关 agent 的模板，
        必须与 tools/hermes-paw-qr --prompt 字节一致，由 s15-selftest 守护）
  D. Msg.t('x') 引用的 key 必须存在于资源中（防拼写漂移）

用法：python3 tools/i18n-selftest.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "entry" / "src" / "main" / "resources"
ETS = ROOT / "entry" / "src" / "main" / "ets"
CJK = re.compile(r"[\u4e00-\u9fff]")
ALLOW_HARDCODED = {"util/OnboardPrompt.ets"}

ok, fail = [], []


def check(name, cond, detail=""):
    (ok if cond else fail).append(name)
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))


def strip_comments(s: str) -> str:
    """去掉 // 与 /* */ 注释，保留字符串内容（字符串里的 // 不算注释）。"""
    out, i, n, st = [], 0, len(s), "code"
    while i < n:
        c = s[i]
        if st == "code":
            if c == "/" and i + 1 < n and s[i + 1] == "/":
                st = "lc"; i += 2; continue
            if c == "/" and i + 1 < n and s[i + 1] == "*":
                st = "bc"; i += 2; continue
            if c in "'\"":
                st = "str" + c
            out.append(c); i += 1; continue
        if st == "lc":
            if c == "\n":
                st = "code"; out.append(c)
            i += 1; continue
        if st == "bc":
            if c == "*" and i + 1 < n and s[i + 1] == "/":
                st = "code"; i += 2; continue
            i += 1; continue
        q = st[-1]
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(s[i + 1]); i += 2; continue
        if c == q:
            st = "code"
        i += 1
    return "".join(out)


def load(loc: str):
    p = RES / loc / "element" / "string.json"
    d = json.load(open(p, encoding="utf-8"))
    return {x["name"]: x["value"] for x in d["string"]}


def main() -> int:
    locs = ["base", "zh_CN", "en_US"]
    tables = {loc: load(loc) for loc in locs}

    # A. key 一致
    base_keys = set(tables["base"])
    for loc in ("zh_CN", "en_US"):
        missing = base_keys - set(tables[loc])
        extra = set(tables[loc]) - base_keys
        check(f"A key 一致 {loc}（{len(tables[loc])} 条）", not missing and not extra,
              f"缺 {sorted(missing)[:5]} 多 {sorted(extra)[:5]}")

    # B. en_US 无中文
    zh_left = [k for k, v in tables["en_US"].items() if CJK.search(v)]
    check("B en_US 无中文残留", not zh_left, f"{len(zh_left)} 条: {zh_left[:5]}")

    # C. 代码区无硬编码中文
    bad = []
    for f in sorted(ETS.rglob("*.ets")):
        rel = f.relative_to(ETS).as_posix()
        if rel in ALLOW_HARDCODED:
            continue
        code = strip_comments(f.read_text(encoding="utf-8"))
        for m in re.finditer(r"'([^'\n]*[\u4e00-\u9fff][^'\n]*)'", code):
            bad.append(f"{rel}: {m.group(1)[:24]}")
    check("C 代码区零硬编码中文", not bad, f"{len(bad)} 处: {bad[:3]}")

    # D. Msg.t 的 key 存在
    unknown = []
    for f in sorted(ETS.rglob("*.ets")):
        src = strip_comments(f.read_text(encoding="utf-8"))
        for m in re.finditer(r"Msg\.t\('([A-Za-z0-9_]+)'\)", src):
            if m.group(1) not in base_keys:
                unknown.append(f"{f.name}: {m.group(1)}")
    check("D Msg.t key 均已定义", not unknown, f"{len(unknown)} 个未定义: {unknown[:3]}")

    print(f"\ni18n-selftest: {'PASS' if not fail else 'FAIL'} ({len(ok)}/{len(ok) + len(fail)})")
    return 0 if not fail else 1


if __name__ == "__main__":
    sys.exit(main())
