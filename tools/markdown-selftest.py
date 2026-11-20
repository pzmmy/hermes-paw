#!/usr/bin/env python3
"""L2 gate: P4⑦ lightweight-Markdown self-test.

Pure static + logic-mirror test — NO gateway, NO ArkTS compiler (236 has no
DevEco SDK). Verifies:
  1. Markdown.ets exists and exports the required surface (MdBlock, MdSeg,
     parseInline, parseMarkdownBlocks).
  2. ArkTS forbidden-syntax check on Markdown.ets (no var / any / template
     literal / new Object() / Date.getTime()).
  3. Deliberate NARROW subset: the parser does NOT attempt code fences (```)
     or list markers ( - / 1. ) — those are excluded by design (spec §9-7).
  4. Wiring: ChatPage imports the parser, defines mdParse + @Builder mdView,
     and renders it for the finalized assistant bubble (thinking + no-thinking
     branches) AND the streaming bubble (>= 3 call sites).
  5. Logic mirror: a faithful Python re-implementation of parseInline +
     parseMarkdownBlocks run against the spec's edge cases, including the
     streaming half-content guarantees (unclosed ** / open table row degrade
     to plain text, never crash, never half-bold).

Zero-dep (stdlib only). Relative paths (repo root = this file's parent).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MD = ROOT / "entry" / "src" / "main" / "ets" / "model" / "Markdown.ets"
PAGE = ROOT / "entry" / "src" / "main" / "ets" / "pages" / "ChatPage.ets"

FAILS = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"  ok  {msg}")
    else:
        print(f"  FAIL {msg}")
        FAILS.append(msg)


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("//"))


# ---------------- 1/2/3: Markdown.ets static ----------------
print("== Markdown.ets ==")
if not MD.exists():
    print(f"  FAIL {MD} missing")
    sys.exit(1)
src = MD.read_text(encoding="utf-8")
code = strip_comments(src)

for sym in ["export interface MdBlock", "export interface MdSeg",
            "export function parseInline", "export function parseMarkdownBlocks"]:
    check(sym in src, f"exports {sym.split()[-1] + ' / ' + sym.split()[-2] if 'function' in sym else sym}")

# 2: ArkTS forbidden syntax
check(not re.search(r"(?m)^\s*var\s+\w", code), "no 'var' declarations")
check(not re.search(r":\s*any\b|<any>|as any\b", code), "no 'any' type")
check("`" not in code, "no template literals")
check("new Object(" not in code, "no new Object()")
check("Date.getTime(" not in code and "Date.now(" not in code, "no Date time calls")
check(not re.search(r"\bnew\s+\w+\s*[^;]*=>", code), "no object-literal-as-Object misuse")

# 3: deliberate exclusions (parser must NOT handle fences or list markers)
check("```" not in code, "no code-fence handling (deliberately excluded)")
# list detection would key on a leading '- ' or 'N. ' — the parser keys only
# on '#' / '![' / '|'. Verify none of the branch conditions test a list marker.
check(not re.search(r"charAt\(0\)\s*===\s*'-'", code), "no list-marker('- ') branch")
check(not re.search(r"matches|listMarker|ordered|unordered", code, flags=re.I), "no list logic keywords")

# ---------------- 4: ChatPage wiring ----------------
print("== ChatPage wiring ==")
pcode = PAGE.read_text(encoding="utf-8")
check("from '../model/Markdown'" in pcode, "imports model/Markdown")
check(re.search(r"\bmdParse\s*\(", pcode) is not None, "defines mdParse()")
check("@Builder" in pcode and re.search(r"\bmdView\s*\(", pcode) is not None, "defines @Builder mdView")
# call sites: finalized assistant (thinking + no-thinking) + streaming = >= 3
calls = len(re.findall(r"this\.mdView\(", pcode))
check(calls >= 3, f"mdView rendered at {calls} call sites (need >= 3: thinking + no-thinking + streaming)")
check("Text() {" in pcode and "Span(" in pcode, "para uses Text(){Span()} inline")
check("ScrollDirection.Horizontal" in pcode, "table uses horizontal Scroll")

# ---------------- 5: logic mirror ----------------
print("== parser logic mirror ==")


def parse_inline(text: str):
    """Mirror of parseInline: bold (**…**) + link ([t](u)); unclosed → literal."""
    segs = []
    i, n, buf = 0, len(text), ""

    def flush():
        nonlocal buf
        if buf:
            segs.append({"text": buf, "bold": False, "link": ""})
            buf = ""

    while i < n:
        ch = text[i]
        if ch == "*" and i + 1 < n and text[i + 1] == "*":
            close = text.find("**", i + 2)
            if close != -1:
                flush()
                segs.append({"text": text[i + 2:close], "bold": True, "link": ""})
                i = close + 2
                continue
        if ch == "[":
            rb = text.find("]", i + 1)
            if rb != -1 and rb + 1 < n and text[rb + 1] == "(":
                rp = text.find(")", rb + 2)
                if rp != -1:
                    flush()
                    segs.append({"text": text[i + 1:rb], "bold": False, "link": text[rb + 2:rp]})
                    i = rp + 1
                    continue
        buf += ch
        i += 1
    flush()
    return segs


def parse_image_url(line: str) -> str:
    if line[:2] != "![":
        return ""
    rb = line.find("]")
    if rb == -1 or rb + 1 >= len(line) or line[rb + 1] != "(":
        return ""
    rp = line.find(")", rb + 2)
    if rp == -1:
        return ""
    return line[rb + 2:rp].strip()


def split_table_row(line: str):
    t = line.strip()
    if t.startswith("|"):
        t = t[1:]
    if t.endswith("|"):
        t = t[:-1]
    return [c.strip() for c in t.split("|")]


def is_separator_row(cells):
    any_dash = False
    for c in cells:
        if c == "":
            continue
        if not re.fullmatch(r"[-: ]+", c):
            return False
        if "-" in c:
            any_dash = True
    return any_dash


def parse_blocks(text: str):
    """Mirror of parseMarkdownBlocks → list of (type, payload)."""
    blocks = []
    if text == "":
        return blocks
    lines = text.split("\n")
    para, table = [], []

    def flush_para():
        nonlocal para
        if para:
            joined = " ".join(para).strip()
            if joined:
                blocks.append(("para", joined, parse_inline(joined)))
            para = []

    def flush_table():
        nonlocal table
        if table:
            blocks.append(("table", [list(r) for r in table], None))
            table = []

    for ln in lines:
        t = ln.strip()
        if t.startswith("#"):
            level = 0
            while level < len(t) and t[level] == "#":
                level += 1
            if 1 <= level <= 6 and (level == len(t) or t[level] == " "):
                flush_para(); flush_table()
                blocks.append(("heading", level, t[level:].strip()))
                continue
        if t[:2] == "![":
            url = parse_image_url(t)
            if url:
                flush_para(); flush_table()
                blocks.append(("image", url, None))
                continue
        if "|" in t:
            flush_para()
            cells = split_table_row(t)
            if is_separator_row(cells):
                continue
            table.append(cells)
            continue
        if t == "":
            flush_para(); flush_table()
            continue
        flush_table()
        para.append(t)
    flush_para(); flush_table()
    return blocks


# 5a: heading
b = parse_blocks("# 标题\n## 二级\n### 三级")
check([x[0] for x in b] == ["heading", "heading", "heading"], "headings # ## ###")
check([x[1] for x in b] == [1, 2, 3], "heading levels 1/2/3")
check(b[0][2] == "标题" and b[1][2] == "二级", "heading text stripped of #")

# 5b: table (with separator row skipped)
b = parse_blocks("| A | B |\n|---|---|\n| 1 | 2 |")
check(len(b) == 1 and b[0][0] == "table", "single table block")
check(b[0][1] == [["A", "B"], ["1", "2"]], "separator row skipped, 2 data rows")
check(len(b[0][1][0]) == 2, "2 columns")

# 5c: image
b = parse_blocks("![alt](https://x.com/a.png)")
check(len(b) == 1 and b[0][0] == "image" and b[0][1] == "https://x.com/a.png", "image url extracted")

# 5d: para with bold + link
b = parse_blocks("Hello **world** and [docs](https://d.com)")
check(len(b) == 1 and b[0][0] == "para", "single para")
segs = b[0][2]
check(any(s["bold"] and s["text"] == "world" for s in segs), "bold segment 'world'")
check(any(s["link"] == "https://d.com" and s["text"] == "docs" for s in segs), "link segment 'docs'")
check(any(s["text"] == "Hello " for s in segs), "leading plain segment")

# 5e: streaming half-content — unclosed ** degrades to literal (no crash, no half-bold)
b = parse_blocks("partial **unclosed bold here")
check(len(b) == 1 and b[0][0] == "para", "unclosed ** → para (no crash)")
segs = b[0][2]
check(not any(s["bold"] for s in segs), "unclosed ** → NO bold segment (literal)")
check("".join(s["text"] for s in segs) == "partial **unclosed bold here", "unclosed ** text preserved verbatim")

# 5f: streaming half-content — open table row (no trailing newline, in progress)
b = parse_blocks("| col1 | col2 |")
check(len(b) == 1 and b[0][0] == "table" and b[0][1] == [["col1", "col2"]], "single open table row → 1 row")

# 5g: streaming half-content — half image (no closing paren) degrades to para
b = parse_blocks("![alt](https://x.com/a.pn")
check(len(b) == 1 and b[0][0] == "para", "half image → para (no crash)")

# 5h: mixed document (heading + para + table)
doc = "# 概览\n\n一句话总结\n\n| 项 | 值 |\n|---|---|\n| a | 1 |"
b = parse_blocks(doc)
check([x[0] for x in b] == ["heading", "para", "table"], "mixed doc order heading→para→table")
check(b[1][1] == "一句话总结", "mixed para text")

# 5i: empty
check(parse_blocks("") == [], "empty text → no blocks")

# 5j: link with no url (unclosed) → literal
segs = parse_inline("a [broken](not closed")
check(not any(s["link"] for s in segs), "unclosed link → no link segment")
check("".join(s["text"] for s in segs) == "a [broken](not closed", "unclosed link preserved verbatim")

# ---------------- summary ----------------
print()
if FAILS:
    print(f"markdown-selftest: {len(FAILS)} FAIL")
    sys.exit(1)
print("markdown-selftest: ALL PASS")
sys.exit(0)
