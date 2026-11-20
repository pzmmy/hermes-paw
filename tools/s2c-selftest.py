#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""paw-S2 (§R3: 放弃条件由 status 决定，不由墙钟决定) 静态自测。

纯静态断言，无 gateway、无 ArkTS 编译器、零依赖（stdlib only）。
扫描对象 = 本文件父目录下的 entry/src/main/ets 树（与 s3-selftest.py 同风格，
repo root = 本文件的 parent）。

6 条检查（对应 TASK paw-S2 §顺手要做的）:
  1. RECOVER_TIMEOUT_MS / RECOVER_POLL_TIMEOUT_MS 在 *.ets 中零命中（含注释）
  2. ABSOLUTE_CAP_MS 存在且字面量为 30 * 60 * 1000
  3. GETRUN_FAIL_LIMIT = 3、UNKNOWN_STATUS_LIMIT = 3 存在
  4. 'connection-lost' / 'protocol-error' / 'abandoned-remote' 各命中 >= 1
  5. ChatVM.ets 中 finalizeRun(...'recovery-timeout'...) 调用点为 0（注释内提及不计）
  6. failStreak / unknownStreak 的 `= 0` 赋值次数各 >= 3（初始化 + 成功归零 + 收口归零）

追加 2 条（TASK paw-S2fix：active 白名单漏状态 = 正常 run 被 6 秒误收口）:
  7. ChatVM.ets 的 isKnownActiveStatus() 函数体内引用 QUEUED / CLAIMED / STOPPING /
     FINALIZING / SCHEDULED 各 >= 1（漏一个就会把该状态的 run 判成 protocol-error）
  8. Run.ets 中 queued / claimed / scheduled / stopping / finalizing 五个字面量各 >= 1
     （枚举值必须是网关字面量，不能自造拼写）

用法: python3 tools/s2-selftest.py
退出码: 0 = 全绿, 1 = 存在 FAIL
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / 'entry' / 'src' / 'main' / 'ets'
VM = ETS / 'viewmodel' / 'ChatVM.ets'
# S3a 拆分后，放弃判据/active 状态集搬到独立模块；断言必须同时看两个文件，
# 否则搬家会让 check2/3/4/5/7 误报"零命中"。
POLICY = ETS / 'viewmodel' / 'stream' / 'RunPolicy.ets'
RUN_MODEL = ETS / 'model' / 'Run.ets'

RESULTS = []


def strip_comments(src):
    """去掉 // 与 /* */ 注释，保留换行以便行号仍可定位（字符串内的 // 不误删）。"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if ch == '/' and nxt == '/':
            while i < n and src[i] != '\n':
                i += 1
            if i < n:            # 保留换行，否则行号会向后漂移
                out.append('\n')
                i += 1
            continue
        if ch == '/' and nxt == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                if src[i] == '\n':
                    out.append('\n')
                i += 1
            i += 2
            continue
        if ch in ('"', "'"):
            quote = ch
            out.append(ch)
            i += 1
            while i < n:
                if src[i] == '\\':
                    out.append(src[i:i + 2])
                    i += 2
                    continue
                out.append(src[i])
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def read(path):
    return path.read_text(encoding='utf-8')


def strip_keep_lines(src):
    """去注释但保持行数不变（行号可用于报错定位）。"""
    return strip_comments(src)


def check(name, ok, hits):
    RESULTS.append((name, ok))
    if ok:
        print('[OK] %s' % name)
        return
    print('[FAIL] %s' % name)
    for h in hits:
        print('       %s' % h)


def locs(lines, pattern):
    """返回 pattern 命中的 'file:line: text' 列表。"""
    rx = re.compile(pattern)
    out = []
    for idx, line in enumerate(lines, 1):
        if rx.search(line):
            out.append('%s:%d: %s' % (VM, idx, line.strip()))
    return out


def fn_body(code, name):
    """抽取 `function <name>(...) { ... }` 的函数体（花括号配平，跳过字符串）。

    返回 (body, start_line)；没找到返回 ('', 0)。用于把断言限定在函数体内，
    而不是整文件——否则别处一句注释/日志就能让检查假绿。
    """
    m = re.search(r'function\s+' + re.escape(name) + r'\s*\(', code)
    if not m:
        return '', 0
    i = code.find('{', m.end())
    if i < 0:
        return '', 0
    start_line = code.count('\n', 0, m.start()) + 1
    depth = 0
    j = i
    n = len(code)
    while j < n:
        ch = code[j]
        if ch in ('"', "'"):
            quote = ch
            j += 1
            while j < n:
                if code[j] == '\\':
                    j += 2
                    continue
                if code[j] == quote:
                    break
                j += 1
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return code[i:j + 1], start_line
        j += 1
    return '', 0


def hits_in(text, name):
    """`name` 在 text 中的出现次数（词边界，避免 QUEUED 命中 XMLQUEUED）。"""
    return len(re.findall(r'\b' + re.escape(name) + r'\b', text))


def main():
    if not VM.is_file():
        print('ENV: ChatVM.ets 不存在: %s' % VM)
        return 2
    if not RUN_MODEL.is_file():
        print('ENV: Run.ets 不存在: %s' % RUN_MODEL)
        return 2
    if not POLICY.is_file():
        print('ENV: RunPolicy.ets 不存在: %s（S3a 拆分产物缺失）' % POLICY)
        return 2
    raw = read(VM)
    raw_policy = read(POLICY)

    # ---------- 检查 1：两道墙钟常量必须彻底消失（注释也不许留）----------
    dead = []
    for idx, line in enumerate(raw.splitlines(), 1):
        if 'RECOVER_TIMEOUT_MS' in line or 'RECOVER_POLL_TIMEOUT_MS' in line:
            dead.append('%s:%d: %s' % (VM, idx, line.strip()))
    other = []
    if ETS.is_dir():
        for p in sorted(ETS.rglob('*.ets')):
            if p == VM:
                continue
            text = read(p)
            for idx, line in enumerate(text.splitlines(), 1):
                if 'RECOVER_TIMEOUT_MS' in line or 'RECOVER_POLL_TIMEOUT_MS' in line:
                    other.append('%s:%d: %s' % (p, idx, line.strip()))
    check('check1 墙钟常量零命中 (RECOVER_TIMEOUT_MS / RECOVER_POLL_TIMEOUT_MS)',
          not dead and not other, dead + other)

    code = strip_keep_lines(raw) + '\n' + strip_keep_lines(raw_policy)
    lines = code.splitlines()

    # ---------- 检查 2：ABSOLUTE_CAP_MS = 30 * 60 * 1000 ----------
    cap_rx = r'const\s+ABSOLUTE_CAP_MS\s*:\s*number\s*=\s*30\s*\*\s*60\s*\*\s*1000\s*;'
    cap_hits = locs(lines, cap_rx)
    check('check2 ABSOLUTE_CAP_MS 存在且字面量 30 * 60 * 1000', len(cap_hits) == 1,
          cap_hits if cap_hits else locs(lines, r'ABSOLUTE_CAP_MS'))

    # ---------- 检查 3：两条 streak 上限常量 ----------
    fail_lim = locs(lines, r'const\s+GETRUN_FAIL_LIMIT\s*:\s*number\s*=\s*3\s*;')
    unk_lim = locs(lines, r'const\s+UNKNOWN_STATUS_LIMIT\s*:\s*number\s*=\s*3\s*;')
    check('check3 GETRUN_FAIL_LIMIT = 3 与 UNKNOWN_STATUS_LIMIT = 3 存在',
          len(fail_lim) == 1 and len(unk_lim) == 1, fail_lim + unk_lim)

    # ---------- 检查 4：三个 reason 字符串各命中 >= 1 ----------
    reasons = ["'connection-lost'", "'protocol-error'", "'abandoned-remote'"]
    missing = []
    for r in reasons:
        if r not in code:
            missing.append('%s: %s 零命中' % (VM, r))
    check('check4 三个 reason 字符串各命中 >= 1 (connection-lost/protocol-error/abandoned-remote)',
          not missing, missing)

    # ---------- 检查 5：finalizeRun 不再用 'recovery-timeout' ----------
    bad = locs(lines, r"finalizeRun\s*\([^)]*'recovery-timeout'")
    check("check5 finalizeRun(...'recovery-timeout'...) 调用点为 0（注释提及不计）",
          not bad, bad)

    # ---------- 检查 6：两个 streak 各 >= 3 次 `= 0` ----------
    fail_zero = locs(lines, r'this\.failStreak\s*=\s*0\s*;')
    unk_zero = locs(lines, r'this\.unknownStreak\s*=\s*0\s*;')
    ok6 = len(fail_zero) >= 3 and len(unk_zero) >= 3
    hits6 = []
    if len(fail_zero) < 3:
        hits6.append('%s: failStreak = 0 仅 %d 次（需 >= 3）' % (VM, len(fail_zero)))
    if len(unk_zero) < 3:
        hits6.append('%s: unknownStreak = 0 仅 %d 次（需 >= 3）' % (VM, len(unk_zero)))
    check('check6 failStreak/unknownStreak 的 = 0 各 >= 3（初始化 + 成功归零 + 收口归零）',
          ok6, hits6)
    print('       failStreak=0 x%d @ %s' % (len(fail_zero), ', '.join(
        h.split(':')[1] for h in fail_zero)))
    print('       unknownStreak=0 x%d @ %s' % (len(unk_zero), ', '.join(
        h.split(':')[1] for h in unk_zero)))

    # ---------- 检查 7：isKnownActiveStatus 函数体必须覆盖 5 个漏掉的 active 状态 ----------
    body, body_line = fn_body(code, 'isKnownActiveStatus')
    need7 = ['QUEUED', 'CLAIMED', 'SCHEDULED', 'STOPPING', 'FINALIZING']
    hits7 = []
    if not body:
        hits7.append('%s: 找不到 isKnownActiveStatus 函数体' % VM)
    else:
        for st in need7:
            c = hits_in(body, st)
            if c < 1:
                hits7.append('ChatVM+RunPolicy 合并文本: isKnownActiveStatus 体缺 RunStatus.%s（%d 命中）'
                             % (st, c))
    check('check7 isKnownActiveStatus 覆盖 QUEUED/CLAIMED/SCHEDULED/STOPPING/FINALIZING（漏一个 = 该状态 run 被 6s 误收口）',
          not hits7, hits7)
    print('       body @ %s:%d  %s' % (VM, body_line, ' '.join(
        '%s=%d' % (st, hits_in(body, st)) for st in need7)))

    # ---------- 检查 8：Run.ets 里 5 个网关字面量各 >= 1 ----------
    raw_run = read(RUN_MODEL)
    run_code = strip_keep_lines(raw_run)
    need8 = ['queued', 'claimed', 'scheduled', 'stopping', 'finalizing']
    hits8 = []
    for lit in need8:
        c = len(re.findall(r"'" + lit + r"'", run_code))
        if c < 1:
            hits8.append("%s: 字面量 '%s' 零命中" % (RUN_MODEL, lit))
    check("check8 Run.ets 含网关字面量 'queued'/'claimed'/'scheduled'/'stopping'/'finalizing' 各 >= 1",
          not hits8, hits8)
    print('       %s  %s' % (RUN_MODEL, ' '.join(
        "%s=%d" % (lit, len(re.findall(r"'" + lit + r"'", run_code))) for lit in need8)))

    failed = [n for n, ok in RESULTS if not ok]
    print('SUMMARY: total=%d pass=%d fail=%d' %
          (len(RESULTS), len(RESULTS) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())