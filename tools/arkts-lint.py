#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ArkTS strict-mode static lint (236 deliverable).

Encodes the ArkTS strictness rules learned from the S1 DevEco build
rounds (11 ERROR -> 2 fix rounds). Run on 236 BEFORE pushing, so the
main controller's DevEco build starts clean.

Rules:
  L1 no `var` declarations            (use const/let)
  L2 no `any` type                    (ArkTS strict typing)
  L3 no template literals (backtick)  (forbidden in this codebase)
  L4 no `new Object()` / `new Array()`
  L5 no `.getTime()`                   (project constraint; use Date.now())
  L6 build() body: no local const/let/var statements
     (ArkUI 10905209: build() only allows UI component syntax;
      move locals to accessor methods)
  L7 pages/*.ets must declare @Entry
  L8 brace/paren/bracket balance per file
  L9 duplicate let/const declaration in the same block scope
     (Ark compiler: redeclaration is a hard error; the 8be379c
      incident — `let pa` twice in one method body — is invisible
      to all other rules)

Usage:
  python3 tools/arkts-lint.py [ROOT]     # default: repo root

Exit: 0 = clean, 1 = findings.
"""
import json
import re
import sys
from pathlib import Path

RULES_DESC = {
    "L1": "var declaration (use const/let)",
    "L2": "any type",
    "L3": "template literal backtick",
    "L4": "new Object()/new Array()",
    "L5": ".getTime() (use Date.now())",
    "L6": "local const/let/var statement in build() body",
    "L7": "page file missing @Entry",
    "L8": "unbalanced braces/parens/brackets",
    "L9": "duplicate let/const in same block scope",
}


def strip_code(src: str) -> str:
    """Remove comments and string literals (backtick-free by L3 design)."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif c in ("'", '"'):
            q = c
            i += 1
            while i < n and src[i] != q:
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1
            out.append('""')
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check_balance(code: str, path: Path, findings: list):
    for open_c, close_c, name in (("{", "}", "braces"),
                                  ("(", ")", "parens"),
                                  ("[", "]", "brackets")):
        o = code.count(open_c)
        c = code.count(close_c)
        if o != c:
            findings.append((path, "L8", -1,
                             "%s %d vs %d" % (name, o, c)))


def check_build_locals(code: str, path: Path, findings: list):
    """Flag const/let/var statements at depth 0 of build() bodies."""
    for m in re.finditer(r"\bbuild\s*\(\s*\)\s*\{", code):
        start = m.end() - 1
        depth = 0
        j = start
        while j < len(code):
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = code[start + 1:j]
        depth = 0
        line_no = code[:start].count("\n")
        for raw in body.split("\n"):
            if depth == 0 and re.match(r"\s*(const|let|var)\s+[A-Za-z_$]", raw):
                findings.append((path, "L6", line_no + 1,
                                 "local statement in build(): %s" % raw.strip()[:60]))
            for ch in raw:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
            line_no += 1


def check_redecl(code: str, path: Path, findings: list):
    """L9: duplicate let/const declaration in the same block scope.

    Walks braces and declarations in source order, keeping a stack of
    per-block name sets. `for (` pushes a for-init scope frame popped
    at its matching `)` (a for-init binding dies with the statement).
    Object-literal braces push/pop frames too — harmless, because
    property names are never let/const declarations.
    """
    tok_re = re.compile(
        r"[\{\}]"
        r"|\bfor\s*\("
        r"|[()]"
        r"|(?<![\w$.])(?:let|const)\s+([A-Za-z_$][A-Za-z0-9_$]*)")
    scopes = [set()]
    in_for = False
    for_depth = 0
    line = 1
    last = 0
    for m in tok_re.finditer(code):
        line += code.count("\n", last, m.start())
        last = m.end()
        tok = m.group(0)
        if tok == "{":
            scopes.append(set())
        elif tok == "}":
            if len(scopes) > 1:
                scopes.pop()
        elif tok.startswith("for"):
            in_for = True
            for_depth = 1
            scopes.append(set())
        elif in_for and tok == "(":
            for_depth += 1
        elif in_for and tok == ")":
            for_depth -= 1
            if for_depth == 0:
                in_for = False
                scopes.pop()
        else:
            name = m.group(1)
            if name is None:
                continue  # bare ( / ) outside a for-init
            top = scopes[-1]
            if name in top:
                findings.append((path, "L9", line,
                                 "redeclared in same block: %s" % name))
            else:
                top.add(name)


def lint_file(path: Path, findings: list):
    src = path.read_text(encoding="utf-8", errors="replace")
    code = strip_code(src)
    rel = path

    def lineno_at(s: str, pos: int) -> int:
        return s.count("\n", 0, pos) + 1

    for m in re.finditer(r"\bvar\s+[A-Za-z_$]", code):
        findings.append((rel, "L1", lineno_at(code, m.start()),
                         m.group(0).split()[0]))
    for m in re.finditer(r"(:\s*any\b|as\s+any\b|<any>)", code):
        findings.append((rel, "L2", lineno_at(code, m.start()),
                         m.group(0).strip()))
    for m in re.finditer(r"`", code):
        findings.append((rel, "L3", lineno_at(code, m.start()), "backtick"))
    for m in re.finditer(r"new\s+(Object|Array)\s*\(", code):
        findings.append((rel, "L4", lineno_at(code, m.start()),
                         "new %s(" % m.group(1)))
    for m in re.finditer(r"\.getTime\s*\(", code):
        findings.append((rel, "L5", lineno_at(code, m.start()), ".getTime()"))

    check_build_locals(code, rel, findings)
    check_balance(code, rel, findings)
    check_redecl(code, rel, findings)


def lint_entry(root: Path, findings: list):
    """L7: every page listed in main_pages.json must be @Entry (10905402).

    Components embedded in a Tab/Navigation layout (e.g. ChatPage/
    SettingsPage inside Index) are NOT router pages and must not be
    flagged — only the src list in main_pages.json counts.
    """
    for mp in root.glob("entry/src/main/resources/*/profile/main_pages.json"):
        try:
            data = json.loads(mp.read_text(encoding="utf-8"))
        except Exception as e:
            findings.append((mp, "L7", 1, "main_pages.json unreadable: %s" % e))
            continue
        ets_root = mp.parent.parent.parent.parent / "ets"
        for src in data.get("src", []):
            f = ets_root / (src + ".ets")
            if not f.is_file():
                findings.append((mp, "L7", 1, "listed page missing: %s" % src))
                continue
            if "@Entry" not in f.read_text(encoding="utf-8", errors="replace"):
                findings.append((f, "L7", 1,
                                 "main_pages.json entry missing @Entry"))


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parent.parent
    ets_dir = root / "entry" / "src" / "main" / "ets"
    if not ets_dir.is_dir():
        print("ERROR: %s not found" % ets_dir)
        sys.exit(2)
    files = sorted(ets_dir.rglob("*.ets"))
    findings = []
    for f in files:
        lint_file(f, findings)
    lint_entry(root, findings)
    for f, rule, ln, detail in findings:
        print("[FAIL] %-38s %s:%d  %s — %s"
              % (str(f.relative_to(root)), rule, ln, RULES_DESC[rule], detail))
    print("--------------------------------------------------")
    print("arkts-lint: %d files, %d findings" % (len(files), len(findings)))
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
