#!/usr/bin/env python3
"""L2 gate: P5 slash-command self-test (table consistency + wiring presence
+ intercept-logic regression).

Pure static / logic-mirror test — NO gateway, NO ArkTS compiler (236 has no
DevEco SDK). Verifies:
  1. SlashCommands.ets: mapped (SLASH_COMMANDS) and unmapped (KNOWN_UNMAPPED)
     tables are non-empty, disjoint, no duplicate names.
  2. Wiring: every mapped command has a handleCmd* handler in ChatVM.ets;
     ChatVM.sendMessage calls handleSlashCommand; ChatPage renders the
     MessageRole.SYSTEM bubble branch; SessionsApi.setTitle exists.
  3. Logic mirror (Python re-implementation of slashName/slashArg + the
     intercept decision) against the spec's edge cases (§P5): /new,
     /title 新标题, /resume [1|报销], /approve once, /stop (trailing space),
     known-unmapped -> "not supported", unknown /xxx -> fall through.

Zero-dep (stdlib only). Relative paths (repo root = this file's parent).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SC = ROOT / "entry" / "src" / "main" / "ets" / "net" / "SlashCommands.ets"
VM = ROOT / "entry" / "src" / "main" / "ets" / "viewmodel" / "ChatVM.ets"
PAGE = ROOT / "entry" / "src" / "main" / "ets" / "pages" / "ChatPage.ets"
SESS = ROOT / "entry" / "src" / "main" / "ets" / "net" / "SessionsApi.ets"


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("//"))


def extract_tables():
    src = strip_comments(SC.read_text(encoding="utf-8"))
    # Mapped: `name: '/xxx'` occurs only in SLASH_COMMANDS entries
    # (the interface field is `name: string;` — no quotes, won't match).
    mapped = re.findall(r"name:\s*'(/[^']*)'", src)
    # Unmapped: the KNOWN_UNMAPPED string[] body.
    m = re.search(r"KNOWN_UNMAPPED\s*:\s*string\[\]\s*=\s*\[(.*?)\];", src, flags=re.S)
    unmapped = re.findall(r"'(/[^']*)'", m.group(1)) if m else []
    return mapped, unmapped


def slash_name(text: str) -> str:
    t = text.strip()
    if t == "":
        return ""
    sp = t.find(" ")
    return t if sp < 0 else t[:sp]


def slash_arg(text: str) -> str:
    t = text.strip()
    sp = t.find(" ")
    if sp < 0:
        return ""
    return t[sp + 1:].strip()


def intercept(text: str, mset, uset) -> str:
    """Mirror of sendMessage guard + handleSlashCommand return:
    'no-intercept' (not '/'-prefixed) | 'handled' (mapped) |
    'not-supported' (known unmapped) | 'fall-through' (unknown /xxx)."""
    if text.strip()[:1] != "/":
        return "no-intercept"
    name = slash_name(text)
    if name in mset:
        return "handled"
    if name in uset:
        return "not-supported"
    return "fall-through"


def main() -> int:
    print("=== P5 slash-command self-test ===")
    rc = 0

    for f, label in ((SC, "SlashCommands.ets"), (VM, "ChatVM.ets"),
                     (PAGE, "ChatPage.ets"), (SESS, "SessionsApi.ets")):
        if not f.exists():
            print(f"[files] FAIL: {label} 不存在（需完整仓库 checkout）")
            return 1
    print("[files] OK   4 个目标文件均在")

    # 1. table consistency
    mapped, unmapped = extract_tables()
    if not mapped:
        print("[table] FAIL: SLASH_COMMANDS 为空（提取失败）")
        rc = 1
    else:
        print(f"[table] OK   已映射 {len(mapped)}: {', '.join(mapped)}")
    if not unmapped:
        print("[table] FAIL: KNOWN_UNMAPPED 为空（提取失败）")
        rc = 1
    else:
        print(f"[table] OK   未映射 {len(unmapped)}: {', '.join(unmapped)}")
    overlap = set(mapped) & set(unmapped)
    if overlap:
        print(f"[table] FAIL: 已映射 ∩ 未映射 非空: {sorted(overlap)}")
        rc = 1
    else:
        print("[table] OK   已映射 ∩ 未映射 = ∅")
    if len(set(mapped)) != len(mapped):
        dups = sorted({x for x in mapped if mapped.count(x) > 1})
        print(f"[table] FAIL: SLASH_COMMANDS 重复 name: {dups}")
        rc = 1

    # 2. wiring presence
    vm = VM.read_text(encoding="utf-8")
    expected_handlers = {
        "/new": "handleCmdNew", "/resume": "handleCmdResume",
        "/title": "handleCmdTitle", "/stop": "handleCmdStop",
        "/approve": "handleCmdApprove",
    }
    for name in mapped:
        handler = expected_handlers.get(name)
        if handler is None:
            print(f"[wire] FAIL: 映射命令 {name} 无 handler 期望（扩展 selftest expected_handlers）")
            rc = 1
        elif handler not in vm:
            print(f"[wire] FAIL: {name} 的 handler {handler} 未在 ChatVM.ets 出现")
            rc = 1
        else:
            print(f"[wire] OK   {name} -> {handler}")
    if "handleSlashCommand" not in vm:
        print("[wire] FAIL: ChatVM 未见 handleSlashCommand 拦截调用")
        rc = 1
    else:
        print("[wire] OK   sendMessage 拦截 handleSlashCommand 在")
    page = PAGE.read_text(encoding="utf-8")
    if "m.role === 'system'" not in page:
        print("[wire] FAIL: ChatPage 未渲染 system 气泡分支")
        rc = 1
    else:
        print("[wire] OK   ChatPage system 气泡分支在")
    sess = SESS.read_text(encoding="utf-8")
    if "setTitle" not in sess:
        print("[wire] FAIL: SessionsApi.setTitle 缺失")
        rc = 1
    else:
        print("[wire] OK   SessionsApi.setTitle 在")

    # 3a. slashName/slashArg edge cases (spec §P5)
    cases = [
        ("/new", "/new", ""),
        ("/title 新标题", "/title", "新标题"),
        ("/resume", "/resume", ""),
        ("/resume 1", "/resume", "1"),
        ("/resume 报销", "/resume", "报销"),
        ("/approve once", "/approve", "once"),
        ("/stop ", "/stop", ""),
        ("/stop", "/stop", ""),
    ]
    for text, exp_name, exp_arg in cases:
        gname, garg = slash_name(text), slash_arg(text)
        if gname != exp_name or garg != exp_arg:
            print(f"[logic] FAIL {text!r}: name={gname!r}(期望{exp_name!r}) arg={garg!r}(期望{exp_arg!r})")
            rc = 1
        else:
            print(f"[logic] OK   {text!r} -> name={gname!r} arg={garg!r}")

    # 3b. intercept decision
    mset, uset = set(mapped), set(unmapped)
    decisions = [
        ("/new", "handled"),
        ("/stop", "handled"),
        ("/approve once", "handled"),
        ("/branch", "not-supported"),
        ("/compress", "not-supported"),
        ("/unknown xyz", "fall-through"),
        ("/", "fall-through"),
        ("hello world", "no-intercept"),
    ]
    for text, exp in decisions:
        got = intercept(text, mset, uset)
        if got != exp:
            print(f"[intercept] FAIL {text!r}: {got} (期望 {exp})")
            rc = 1
        else:
            print(f"[intercept] OK   {text!r} -> {got}")

    print("SLASH_SELFTEST:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
