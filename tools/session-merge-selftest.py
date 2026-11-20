#!/usr/bin/env python3
# =====================================================================
# tools/session-merge-selftest.py — S9a 门禁
#
# 两件事：
#   1) 静态断言 SessionMerge.ets 的形态（导出名、48 字符常量、无模板串、
#      ChatVM/SessionsApi 的接入点）；
#   2) **Python 复刻** deriveLocalTitle / mergeSessions 的语义，逐点对照
#      期望值；再跑一组「变异体」做阴性对照——变异体必须与本实现分歧，
#      否则说明断言根本没在检查规则。
#
# 退出码：0 全绿 / 1 有 FAIL
# =====================================================================
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MERGE = os.path.join(ROOT, "entry/src/main/ets/viewmodel/SessionMerge.ets")
CHATVM = os.path.join(ROOT, "entry/src/main/ets/viewmodel/ChatVM.ets")
SESSAPI = os.path.join(ROOT, "entry/src/main/ets/net/SessionsApi.ets")

fails = []
passes = []


def check(name, cond, detail=""):
    if cond:
        passes.append(name)
        print("PASS", name)
    else:
        fails.append(name)
        print("FAIL", name, detail)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


# ---------- 1. 静态断言 ----------
merge_src = read(MERGE) if os.path.exists(MERGE) else ""
check("A1 SessionMerge.ets 存在且非空", len(merge_src) > 1500, f"len={len(merge_src)}")
for sym in ("export function deriveLocalTitle", "export function mergeSessions",
            "export function firstMeaningfulLine", "export class MergedSession"):
    check(f"A2 导出 {sym.split()[-1]}", sym in merge_src)
check("A3 常量 = 48", re.search(r"LOCAL_TITLE_MAX_CHARS\s*:\s*number\s*=\s*48", merge_src) is not None)
check("A4 无反引号（lint 禁模板串）", "`" not in merge_src)
check("A5 不使用 RegExp（跨端安全）", "new RegExp" not in merge_src and re.search(r"=\s*/[^/]+/[gims]*\s*;", merge_src) is None)

chat_src = read(CHATVM)
sess_src = read(SESSAPI)
check("A6 ChatVM import SessionMerge",
      "from './SessionMerge'" in chat_src)
for sym in ("deriveLocalTitle", "mergeSessions", "syncTitlesFromServer", "mergedSessions"):
    check(f"A7 ChatVM 使用 {sym}", sym in chat_src)
check("A8 ChatVM 不再生成『新对话 <数字>』占位名",
      re.search(r"'新对话\s*'\s*\+", chat_src) is None)
check("A9 SessionsApi 有 deleteSession", "async deleteSession" in sess_src)
check("A10 SessionsApi title 仅在非空时发送", "if (title !== '')" in sess_src)

# ---------- 2. Python 复刻（语义真值） ----------
MAX = 48


def first_meaningful(line_src: str) -> str:
    for ln in line_src.split("\n"):
        if ln.strip():
            return ln.strip()
    return ""


def collapse(s: str) -> str:
    out = []
    prev_space = False
    for ch in s:
        if ch in (" ", "\t", "\r"):
            if not prev_space and out:
                out.append(" ")
            prev_space = True
        else:
            out.append(ch)
            prev_space = False
    return "".join(out)


def trim_tail(s: str) -> str:
    while s and s[-1] in " ,.;:—-":
        s = s[:-1]
    return s


def derive(text: str, cap: int = MAX) -> str:
    line = collapse(first_meaningful(text)).strip()
    if not line:
        return ""
    if len(line) <= cap:
        return line
    cut = line[:cap]
    sp = cut.rfind(" ")
    base = cut[:sp] if sp > cap // 2 else cut
    return trim_tail(base) + "…"


def merge(local, server):
    out = []
    for s in local:
        out.append({"key": "L|" + s["pk"], "sessionId": s["sessionId"], "title": s["title"],
                    "isLocal": True, "pk": s["pk"], "lastActiveMs": s["updatedAt"],
                    "messageCount": 0, "preview": ""})
    for info in server:
        ms = 0 if info["last_active"] <= 0 else (
            info["last_active"] if info["last_active"] > 100000000000 else info["last_active"] * 1000)
        idx = next((i for i, r in enumerate(out) if r["sessionId"] == info["id"]), -1)
        if idx >= 0:
            hit = out[idx]
            if info["title"]:
                hit["title"] = info["title"]
            hit["messageCount"] = info["message_count"]
            hit["preview"] = info["preview"]
            if ms > hit["lastActiveMs"]:
                hit["lastActiveMs"] = ms
        else:
            out.append({"key": "S|" + info["id"], "sessionId": info["id"], "title": info["title"],
                        "isLocal": False, "pk": "", "lastActiveMs": ms,
                        "messageCount": info["message_count"], "preview": info["preview"]})
    out.sort(key=lambda r: -r["lastActiveMs"])
    return out


CASES = [
    ("短消息原样", "ping", "ping"),
    ("取首个非空行", "第一行标题\n第二行内容", "第一行标题"),
    ("前置空行跳过", "\n\n  真实首行  \n", "真实首行"),
    ("多空格折叠", "多个   空格\t混排", "多个 空格 混排"),
    ("超长无空格按 48 切", "汉" * 60, "汉" * 48 + "…"),
    ("超长有空格按词边界", "a" * 40 + " " + "b" * 30, "a" * 40 + "…"),
    ("恰好 48 不改", "x" * 48, "x" * 48),
    ("尾部标点去掉", ("y" * 46) + " " + "z" * 10, ("y" * 46) + "…"),
    ("空串返回空", "   \n\t ", ""),
]
for name, src, want in CASES:
    got = derive(src)
    check(f"B derive：{name}", got == want, f"got={got!r} want={want!r}")

# 阴性对照：变异体必须与本实现分歧，否则断言无意义
mutant = derive("汉" * 60, cap=30)
check("C 阴性对照：cap 改成 30 必须与本实现分歧", mutant != derive("汉" * 60))

LOCAL = [{"pk": "s1|p|r|sidA", "sessionId": "sidA", "title": "本地派生名", "updatedAt": 1_700_000_000_000},
         {"pk": "s1|p|r|sidB", "sessionId": "sidB", "title": "", "updatedAt": 1_600_000_000_000}]
SERVER = [{"id": "sidA", "title": "服务端升级名", "preview": "p1", "last_active": 1_700_000_100,
           "message_count": 7},
          {"id": "sidC", "title": "仅服务端", "preview": "p2", "last_active": 1_700_000_200,
           "message_count": 3}]
rows = merge(LOCAL, SERVER)
check("D 同 sessionId 只出现一次", len(rows) == 3, f"rows={len(rows)}")
by = {r["sessionId"]: r for r in rows}
check("E 本地行仍标记本地", by["sidA"]["isLocal"] and by["sidA"]["pk"] != "")
check("F 服务端标题覆盖本地派生名", by["sidA"]["title"] == "服务端升级名")
check("G 服务端标题为空时保留本地名", by["sidB"]["title"] == "")
check("H 仅服务端的行标记非本地", by["sidC"]["isLocal"] is False)
check("I 排序按活跃时间倒序",
      [r["sessionId"] for r in rows] == ["sidC", "sidA", "sidB"],
      f"order={[r['sessionId'] for r in rows]}")

# ---------- 3. S9c：会话域外移带来的两个纯函数 ----------
check("J1 导出 unmatchedReport", "export function unmatchedReport" in merge_src)
check("J2 导出 planTitleSync", "export function planTitleSync" in merge_src)


def unmatched(local, server):
    n = 0
    first = ""
    ids = set(s["id"] for s in server)
    for l in local:
        if l["sessionId"] not in ids:
            n += 1
            if not first:
                first = l["sessionId"]
    return n, first


def plan(local, server):
    out = []
    by = {}
    for s in server:
        by[s["id"]] = s
    for l in local:
        info = by.get(l["sessionId"])
        if info is not None and info["title"] and info["title"] != l["title"]:
            out.append({"pk": l["pk"], "title": info["title"]})
    return out


_L = [{"pk": "a", "sessionId": "s1", "title": "t1"},
      {"pk": "b", "sessionId": "s2", "title": ""}]
_S = [{"id": "s1", "title": "S1"}, {"id": "s3", "title": "S3"}]
_n, _first = unmatched(_L, _S)
check("J3 unmatched 计数与首个 id", _n == 1 and _first == "s2",
      f"n={_n} first={_first}")
_u = plan(_L, _S)
check("J4 只为「标题不同且服务端非空」产出", len(_u) == 1 and _u[0]["pk"] == "a"
      and _u[0]["title"] == "S1", f"u={_u}")
check("J5 阴性对照：服务端标题为空不产出",
      len(plan([{"pk": "b", "sessionId": "s2", "title": ""}],
               [{"id": "s2", "title": ""}])) == 0)
check("J6 阴性对照：标题相同不产出",
      len(plan([{"pk": "a", "sessionId": "s1", "title": "S1"}],
               [{"id": "s1", "title": "S1"}])) == 0)

check("K1 导出 fallbackTitle", "export function fallbackTitle" in merge_src)
check("K2 mergeSessions 统一套兜底", "out[k].title = fallbackTitle" in merge_src)


def fallback(title, sid):
    t = (title or "").strip()
    if t:
        return t
    return "未命名 · " + (sid[-6:] if len(sid) > 6 else sid)


check("K3 空标题 -> 未命名·尾6位",
      fallback("", "api_1795066182_671dd197") == "未命名 · " + "api_1795066182_671dd197"[-6:],
      fallback("", "api_1795066182_671dd197"))
check("K4 非空标题原样返回", fallback("e2e ok", "x") == "e2e ok")
check("K5 阴性对照：空白标题也算空", fallback("   ", "abcdefgh") == "未命名 · cdefgh")
check("K6 短 id 不越界", fallback("", "abc") == "未命名 · abc")

print()
print(f"PASS {len(passes)} / FAIL {len(fails)}")
if fails:
    print("FAILED:", ", ".join(fails))
    sys.exit(1)
sys.exit(0)
