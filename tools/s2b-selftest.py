#!/usr/bin/env python3
"""L2 gate: S2-b (长按气泡  引用/删除) self-test.

Pure static + logic-mirror test — NO gateway, NO ArkTS compiler (236 has no
DevEco SDK), zero-dep (stdlib only). Verifies:
  1. Required symbols exist in ChatVM.ets (quoteContext, quoteMessage,
     clearQuote, deleteMessage), ChatPage.ets (onMenuQuote, onMenuDelete,
     hasQuote, quoteText, onClearQuote) and DbHelper.ets (deleteMessage).
  2. String resources (act_quote, act_delete, replying, delete_msg_title,
     delete_msg_confirm) exist in all 3 locales (base / zh_CN / en_US).
  3. Wiring: the long-press menu has 引用 + 删除 buttons bound to their
     handlers; the "回复中" replying bar is gated by hasQuote() and sits
     ABOVE the unified input Row; the delete confirm dialog uses the danger
     color + delete_msg_confirm copy.
  4. Logic mirror: a faithful Python re-implementation of the quote-prepend
     (one-shot consume + 200-char truncation + empty guards) and the
     by-reference delete filter (x !== m), run against the spec's edge cases.

Relative paths (repo root = this file's parent). Exit 0 = green, 1 = FAIL.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / "entry" / "src" / "main" / "ets"
VM = ETS / "viewmodel" / "ChatVM.ets"
PAGE = ETS / "pages" / "ChatPage.ets"
DB = ETS / "store" / "DbHelper.ets"
RES = ROOT / "entry" / "src" / "main" / "resources"

FAILS = []


def check(cond, msg):
    if cond:
        print("  ok   " + msg)
    else:
        print("  FAIL " + msg)
        FAILS.append(msg)


# ---------------- 1: required symbols ----------------
print("== symbols ==")
vsrc = VM.read_text(encoding="utf-8") if VM.exists() else ""
psrc = PAGE.read_text(encoding="utf-8") if PAGE.exists() else ""
dsrc = DB.read_text(encoding="utf-8") if DB.exists() else ""
for p in (VM, PAGE, DB):
    check(p.exists(), str(p.relative_to(ROOT)) + " exists")

for sym in ["quoteContext", "quoteMessage", "clearQuote", "deleteMessage"]:
    check(sym in vsrc, "ChatVM.ets defines " + sym)
for sym in ["onMenuQuote", "onMenuDelete", "hasQuote", "quoteText", "onClearQuote"]:
    check(sym in psrc, "ChatPage.ets defines " + sym)
check(re.search(r"deleteMessage\s*\(\s*id\s*:\s*number", dsrc) is not None,
      "DbHelper.ets defines deleteMessage(id:number)")

# ---------------- 2: string resources (all 3 locales) ----------------
print("== string resources ==")
for loc in ["base", "zh_CN", "en_US"]:
    f = RES / loc / "element" / "string.json"
    if not f.exists():
        check(False, str(loc) + " string.json exists")
        continue
    s = f.read_text(encoding="utf-8")
    for key in ["act_quote", "act_delete", "replying",
                "delete_msg_title", "delete_msg_confirm"]:
        check(re.search(r'"name"\s*:\s*"%s"' % re.escape(key), s) is not None,
              str(loc) + " has " + key)

# ---------------- 3: wiring ----------------
print("== wiring ==")
check("act_quote" in psrc and "onMenuQuote" in psrc,
      "menu 引用 button -> onMenuQuote")
check("act_delete" in psrc and "onMenuDelete" in psrc,
      "menu 删除 button -> onMenuDelete")
check("hasQuote" in psrc and "replying" in psrc,
      "回复中 bar gated by hasQuote() + replying string")
check("app.color.danger" in psrc, "delete confirm uses danger color")
check("delete_msg_confirm" in psrc, "delete confirm uses delete_msg_confirm copy")
# The replying bar must sit ABOVE the input Row (before the U4 unified bar).
reply_idx = psrc.find("this.hasQuote()")
input_idx = psrc.find("U4: unified input bar")
check(reply_idx != -1 and input_idx != -1 and reply_idx < input_idx,
      "回复中 bar renders before the unified input Row")

# ---------------- 4: logic mirror ----------------
print("== logic mirror ==")


def apply_quote(text, quote_content):
    """Mirror of ChatVM.sendMessage quote-prepend (S2-b).

    quote_content is None when quoteContext is null (no quote in flight).
    Otherwise it is the quoted message's .content. The quoteContext is
    consumed (cleared) whenever it was set — independently of whether the
    prepend fires. The prepend only fires when BOTH the trimmed user text
    and the quote content are non-empty; the quote is truncated to 200 chars
    + '…'. Returns the final outgoing text.
    """
    if quote_content is None:
        return text
    if text.strip() != "" and quote_content != "":
        q = quote_content
        if len(q) > 200:
            q = q[:200] + "…"
        return "> " + q + "\n\n" + text
    return text  # consumed, not prepended


def delete_message(messages, target):
    """Mirror of ChatVM.deleteMessage: keep every element except the one
    identical BY REFERENCE to target (ArkTS: x !== m)."""
    return [m for m in messages if m is not target]


def db_delete_needed(msg):
    """Mirror: the DB row is deleted only when a rowid is present (id > 0).
    In-memory-created messages carry id=0 until reloaded, so they are
    removed from the list only (their DB row, if any, is left alone)."""
    return msg.get("id", 0) > 0


# 4a: quote prepend
check(apply_quote("hello", None) == "hello", "no quote -> text unchanged")
check(apply_quote("", "quoted text") == "", "empty user text -> not prepended")
check(apply_quote("hello", "") == "hello", "empty quote content -> not prepended")
check(apply_quote("   ", "quoted") == "   ", "whitespace-only text -> not prepended")
check(apply_quote("hello", "quoted text") == "> quoted text\n\nhello",
      "short quote -> prepended verbatim (prefix '> ' + blank line)")
long_q = "x" * 250
check(apply_quote("hi", long_q) == "> " + "x" * 200 + "…\n\nhi",
      "long quote (>200) -> truncated to 200 + …")
exact = "y" * 200
check(apply_quote("hi", exact) == "> " + "y" * 200 + "\n\nhi",
      "quote exactly 200 -> not truncated (boundary)")

# 4b: delete filter (by reference)
m1 = {"id": 1, "content": "a"}
m2 = {"id": 2, "content": "b"}
m3 = {"id": 3, "content": "a"}  # same content as m1, different reference
lst = [m1, m2, m3]
out = delete_message(lst, m2)
check(len(out) == 2 and out[0] is m1 and out[1] is m3,
      "delete removes the exact reference, keeps the rest (order preserved)")
check(all(x is not m2 for x in out), "deleted reference absent from result")
check(delete_message(lst, {"id": 99}) == lst,
      "delete of an absent reference -> list unchanged")
out = delete_message(lst, m1)
check(len(out) == 2 and out[0] is m2 and out[1] is m3,
      "duplicate content: only the target reference is removed")

# 4c: DB delete only when a rowid is present
check(db_delete_needed({"id": 0}) is False, "id=0 (in-memory) -> list-only delete")
check(db_delete_needed({"id": 5}) is True, "id=5 (loaded) -> DB row deleted too")

print()
if FAILS:
    print("S2-b selftest FAIL (%d):" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("S2-b selftest PASS (all checks green)")
sys.exit(0)
