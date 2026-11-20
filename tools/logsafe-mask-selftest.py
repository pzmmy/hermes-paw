#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LogSafe.mask 同构自测（纯 Python，不进 app 代码）。

把 entry/src/main/ets/utils/LogSafe.ets 里的 mask() 按 ArkTS 逻辑用 Python
重写一遍，跑一组用例。用途：在不需要 DevEco / 不编译 app 的前提下，先证明
三条规则的语义（键值对、/p/<profile>/、整串长 token）按顺序生效。

规则与 ArkTS 侧逐条对应（顺序不可换）：
  R1  (key|token|authorization|password|secret)\\s*[=:]\\s*(可选 scheme)\\s*值 -> key+sep+"***"
  R2  (https?://host)/p/<profile>  ->  host/p/***
  R3  整串 ^[A-Za-z0-9_-]{32,}$    ->  前4位...(len=N)

零依赖（仅 stdlib）。退出码 0 = 全绿，1 = 有用例失败。
"""
import re
import sys

# 与 LogSafe.ets 中 RE_KV / RE_PROFILE / RE_TOKEN 一一对应
RE_KV = re.compile(
    r'\b(key|token|authorization|password|secret)'
    r'(\s*[=:]\s*)'
    r'((?:Bearer|Basic|Digest|Token)\s+)?'
    r'([^\s&,"\']+)',
    re.IGNORECASE,
)
RE_PROFILE = re.compile(r'(https?://[^/\s]+)/p/([^/\s]+)')
RE_TOKEN = re.compile(r'^[A-Za-z0-9_-]{32,}$')

# 44 位、字符集落在 [A-Za-z0-9] 内的样本（满足 R3 的类）
TOKEN44 = "abcd" + "QWERTYUIOPASDFGHJKLZ" * 2
TOKEN44 = TOKEN44[:44]


def mask(v: str) -> str:
    """LogSafe.mask 的 Python 同构：纯函数、无 IO、无状态、不抛异常。"""
    try:
        if len(v) == 0:
            return ""
        s1 = RE_KV.sub(lambda m: m.group(1) + m.group(2) + "***", v)
        s2 = RE_PROFILE.sub(lambda m: m.group(1) + "/p/***", s1)
        if RE_TOKEN.match(s2):
            return s2[:4] + "...(len=" + str(len(s2)) + ")"
        return s2
    except Exception:
        return ""


CASES = [
    # (名称, 输入, 期望)
    ("R1 key=value", "key=abc123", "key=***"),
    ("R1 token: value", "token: XYZ", "token: ***"),
    ("R2 profile 段", "https://h:8377/p/guest/chat", "https://h:8377/p/***/chat"),
    ("R3 长 token", TOKEN44, "abcd...(len=44)"),
    ("无敏感中文句子不变", "这是一句普通的中文日志，没有任何敏感信息", "这是一句普通的中文日志，没有任何敏感信息"),
    ("空串进空串出", "", ""),
    ("R2 不误伤非 /p/ URL", "https://h:8377/v1/runs", "https://h:8377/v1/runs"),
    ("R1 authorization + Bearer", "authorization: Bearer abcdef", "authorization: ***"),
    ("R1 值止于 &", "secret=abc&x=1", "secret=***&x=1"),
    ("R1 保留分隔符空白", "password = p@ssword", "password = ***"),
    ("R1 一处多键", "x key=1 y token=2", "x key=*** y token=***"),
    ("R2 host 无端口", "http://example.com/p/alice/profile?v=1", "http://example.com/p/***/profile?v=1"),
]


def main() -> int:
    print("LogSafe.mask selftest (python mirror)")
    print("token sample: %s  (len=%d)" % (TOKEN44, len(TOKEN44)))
    print("-" * 62)
    failed = 0
    for idx, (name, src, want) in enumerate(CASES, 1):
        got = mask(src)
        ok = got == want
        if not ok:
            failed += 1
        print("[%s] %02d %-26s in=%r" % ("PASS" if ok else "FAIL", idx, name, src))
        print("        out=%r" % (got,))
        if not ok:
            print("        exp=%r" % (want,))
    print("-" * 62)
    print("cases=%d pass=%d fail=%d" % (len(CASES), len(CASES) - failed, failed))
    if failed:
        print("RESULT: FAIL")
        return 1
    print("RESULT: ALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())