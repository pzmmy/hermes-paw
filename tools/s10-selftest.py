#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""paw-S10a (§R12 第一片: Markdown 渲染缓存 + 节流) 自测。

两段:
  A. 静态断言 (6 条必需 + 1 条防回归) — 扫 out/ 交付树, 零依赖 (stdlib only)
  B. 行为测试 — 本文件内同构复刻一份 MdCache (ARKTS 版 src/utils/MdCache.ets
     的镜像实现, 同样的键/LRU/节流规则), 用可拨动的假时钟跑 4 个用例

静态断言:
  1. utils/MdCache.ets 存在且导出 `class MdCache`
  2. 键拼接里同时出现 `key` 与 `text.length` (按长度命中)
  3. LRU 容量常量存在且 = 8
  4. 节流常量存在且 = 500 (ms)
  5. ChatPage.ets 中 mdView( 的全部调用点都传了 2 个参数 (括号感知计数, 漏一个即红)
  6. ChatPage.ets 中 MdCache.clear() 至少 3 次 (会话切换/新建/删除路径)
  7. (防回归) parseMarkdownBlocks 只在 MdCache.ets 里被调用 — 没有第二条绕开
     缓存的解析路径 (否则缓存形同虚设)

行为用例:
  b1. 同键同长度两次 → parse 次数 = 1
  b2. 长度变化且距上次 parse < 500ms → 返回旧块, parse 次数不增
  b3. 长度变化且距上次 parse > 500ms → 重解析, parse 次数 +1
  b4. 插入 9 个不同键 → 只剩 8 条 (LRU 淘汰生效, 且淘汰最久未用的那条)

用法: python3 tools/s10-selftest.py
退出码: 0 = 全绿, 1 = 存在 FAIL
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / 'entry' / 'src' / 'main' / 'ets'
MD_CACHE = ETS / 'utils' / 'MdCache.ets'
CHAT_PAGE = ETS / 'pages' / 'ChatPage.ets'

RESULTS = []


def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok), detail))
    print(('PASS  ' if ok else 'FAIL  ') + name + (('  — ' + detail) if detail else ''))


def read(path):
    return path.read_text(encoding='utf-8') if path.exists() else ''


def strip_comments(src):
    """去掉 // 与 /* */ 注释, 保留换行 (行号不漂移); 不误删字符串内的 //。"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if ch == '/' and nxt == '/':
            while i < n and src[i] != '\n':
                i += 1
            if i < n:
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
        out.append(ch)
        i += 1
    return ''.join(out)


def split_args(src, open_paren):
    """从 '(' 的下标开始, 返回 (参数个数, 右括号下标)。括号感知, 跳过字符串。"""
    depth = 0
    args = 0
    has_content = False
    i = open_paren
    n = len(src)
    quote = ''
    while i < n:
        ch = src[i]
        if quote:
            if ch == '\\':
                i += 2
                continue
            if ch == quote:
                quote = ''
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            has_content = True
            i += 1
            continue
        if ch in '([{':
            depth += 1
            if depth > 1:
                has_content = True
            i += 1
            continue
        if ch in ')]}':
            depth -= 1
            if depth == 0:
                return (0 if not has_content else args + 1), i
            i += 1
            continue
        if ch == ',' and depth == 1:
            args += 1
            i += 1
            continue
        if depth >= 1 and not ch.isspace():
            has_content = True
        i += 1
    return -1, -1  # unbalanced


# ===================== A. 静态断言 =====================
print('== A. static assertions ==')

cache_src = read(MD_CACHE)
cache_code = strip_comments(cache_src)
page_src = read(CHAT_PAGE)
page_code = strip_comments(page_src)

# 1
check('A1 MdCache.ets exists and exports `class MdCache`',
      MD_CACHE.exists() and re.search(r'\bexport\s+class\s+MdCache\b', cache_code) is not None,
      str(MD_CACHE.relative_to(ROOT)) + ('' if MD_CACHE.exists() else ' MISSING'))

# 2 键拼接 key + text.length
key_expr = None
for m in re.finditer(r'\b(?:const|let)\s+full\s*:\s*string\s*=\s*([^;]+);', cache_code):
    key_expr = m.group(1)
check('A2 cache key concatenates `key` and `text.length`',
      key_expr is not None and re.search(r'\bkey\b', key_expr) is not None
      and re.search(r'\btext\s*\.\s*length\b|\blength\b', key_expr) is not None
      and '+' in key_expr,
      'full = ' + (key_expr.strip() if key_expr else '<not found>'))

# 3 LRU cap = 8
cap = re.search(r'\b(?:const|let)\s+(\w*CAP\w*)\s*:\s*number\s*=\s*(\d+)\s*;', cache_code)
# 4 throttle = 500
thr = re.search(r'\b(?:const|let)\s+(\w*THROTTLE\w*)\s*:\s*number\s*=\s*(\d+)\s*;', cache_code)
check('A3 LRU capacity constant exists and equals 8',
      cap is not None and cap.group(2) == '8',
      (cap.group(1) + ' = ' + cap.group(2)) if cap else '<not found>')
check('A4 throttle constant exists and equals 500 (ms)',
      thr is not None and thr.group(2) == '500',
      (thr.group(1) + ' = ' + thr.group(2)) if thr else '<not found>')

# 5 所有 mdView 调用点都是 2 个参数
sites = []
for m in re.finditer(r'\bthis\s*\.\s*mdView\s*\(', page_code):
    paren = page_code.index('(', m.start())
    argc, close = split_args(page_code, paren)
    line = page_code[:paren].count('\n') + 1
    text = page_code[paren:close + 1] if close > 0 else '<unbalanced>'
    sites.append((line, argc, text))
bad = [s for s in sites if s[1] != 2]
check('A5 every mdView( call site passes exactly 2 args',
      len(sites) >= 3 and not bad,
      '%d call site(s): ' % len(sites)
      + ', '.join('L%d argc=%d %s' % (l, a, t) for l, a, t in sites))
# 声明本身也必须是 2 个参数 (content + key)
decl = re.search(r'\bmdView\s*\(([^)]*)\)\s*\{', page_code)
check('A6 mdView declaration takes (content, key)',
      decl is not None and len([p for p in decl.group(1).split(',') if p.strip()]) == 2,
      decl.group(1).strip() if decl else '<not found>')

# 6 clear() >= 3
clears = [page_code[:m.start()].count('\n') + 1
          for m in re.finditer(r'\bMdCache\s*\.\s*clear\s*\(\s*\)|\bmdCache\s*\.\s*clear\s*\(\s*\)', page_code)]
check('A7 MdCache.clear() appears at least 3 times in ChatPage.ets',
      len(clears) >= 3, 'lines ' + str(clears))

# 7 防回归: parseMarkdownBlocks 只在 MdCache.ets 调用
#    注意排除 model/Markdown.ets —— 那是定义处（`export function parseMarkdownBlocks(`），
#    不是调用路径；把它算成 offender 会让断言永远红。
DEFINER = ETS / 'model' / 'Markdown.ets'
offenders = []
for f in ETS.rglob('*.ets'):
    if f == MD_CACHE or f == DEFINER:
        continue
    code = strip_comments(read(f))
    if re.search(r'[^.\w]parseMarkdownBlocks\s*\(', code):
        offenders.append(str(f.relative_to(ROOT)))
check('A8 no second parse path (parseMarkdownBlocks only called in MdCache.ets)',
      not offenders, ', '.join(offenders) if offenders else 'clean')

# ===================== B. 行为测试 (同构复刻) =====================
print('\n== B. behaviour (python replica of utils/MdCache.ets) ==')

MD_CACHE_CAP = 8
MD_THROTTLE_MS = 500


class Clock:
    def __init__(self):
        self.t = 1000000

    def now(self):
        return self.t

    def advance(self, ms):
        self.t += ms


class ReplicaMdCache:
    """Mirror of the ArkTS MdCache: key + '|' + len(text), LRU 8, 500ms throttle."""
    PARSES = 0

    def __init__(self, clock, parse_fn=None):
        self.clock = clock
        self.entries = []   # [{key, callerKey, length, blocks, parsedAt, usedAt}]
        self.parse_fn = parse_fn or (lambda text: ['b%d' % len(text)])
        self.parses = 0

    def _index_of_key(self, full):
        for i, e in enumerate(self.entries):
            if e['key'] == full:
                return i
        return -1

    def _index_of_caller(self, caller):
        for i, e in enumerate(self.entries):
            if e['callerKey'] == caller:
                return i
        return -1

    def get(self, key, text):
        full = key + '|' + str(len(text))
        now = self.clock.now()
        hit = self._index_of_key(full)
        if hit >= 0:
            self.entries[hit]['usedAt'] = now
            return self.entries[hit]['blocks']
        prev = self._index_of_caller(key)
        if prev >= 0:
            old = self.entries[prev]
            old['usedAt'] = now
            if now - old['parsedAt'] < MD_THROTTLE_MS:
                return old['blocks']
            blocks = self._parse(text)
            del self.entries[prev]
            self._insert(full, key, len(text), blocks, now)
            return blocks
        blocks = self._parse(text)
        self._insert(full, key, len(text), blocks, now)
        return blocks

    def _parse(self, text):
        self.parses += 1
        return self.parse_fn(text)

    def _insert(self, full, key, length, blocks, now):
        self.entries.append({'key': full, 'callerKey': key, 'length': length,
                             'blocks': blocks, 'parsedAt': now, 'usedAt': now})
        while len(self.entries) > MD_CACHE_CAP:
            lru = min(range(len(self.entries)), key=lambda i: self.entries[i]['usedAt'])
            del self.entries[lru]

    def clear(self):
        self.entries = []

    def size(self):
        return len(self.entries)


# extract the real ArkTS constants so the replica cannot drift silently
real_cap = int(cap.group(2)) if cap else -1
real_thr = int(thr.group(2)) if thr else -1
check('B0 replica constants match the ArkTS source',
      real_cap == MD_CACHE_CAP and real_thr == MD_THROTTLE_MS,
      'arkts cap=%d throttle=%d / replica cap=%d throttle=%d'
      % (real_cap, real_thr, MD_CACHE_CAP, MD_THROTTLE_MS))

# b1 同键同长度 → 只解析一次
c = Clock()
m = ReplicaMdCache(c)
r1 = m.get('k', 'hello')
r2 = m.get('k', 'hello')
check('b1 same key + same length -> parse count == 1',
      m.parses == 1 and r1 is r2, 'parses=%d same_blocks=%s' % (m.parses, r1 is r2))

# b2 长度变化 + <500ms → 旧块, 不重解析
c.advance(100)
r3 = m.get('k', 'hello world')
check('b2 length change within 500ms -> stale blocks, no parse',
      m.parses == 1 and r3 is r1, 'parses=%d stale=%s' % (m.parses, r3 is r1))

# b3 再超过 500ms → 重解析 +1
c.advance(500)
r4 = m.get('k', 'hello world')
check('b3 length change after 500ms -> re-parse, parse count == 2',
      m.parses == 2 and r4 is not r1, 'parses=%d new_blocks=%s' % (m.parses, r4 is not r1))

# b4 9 个不同键 → 8 条, 淘汰最久未用的 k1
c2 = Clock()
m2 = ReplicaMdCache(c2)
for i in range(9):
    m2.get('k%d' % i, 't%d' % i)
    c2.advance(10)
keys = sorted(e['callerKey'] for e in m2.entries)
# k0 was touched first -> least recently used, evicted when k8 arrived
check('b4 9 distinct keys -> exactly 8 kept, LRU evicted',
      m2.size() == 8 and 'k0' not in keys and 'k8' in keys,
      'size=%d kept=%s' % (m2.size(), keys))

# 额外: clear() 之后同键必须重解析 (会话切换不串块的机制)
m2.clear()
m2.get('k8', 't8')
check('b5 clear() drops entries -> next get re-parses',
      m2.size() == 1 and m2.parses == 10,
      'size=%d parses=%d' % (m2.size(), m2.parses))

# ===================== 汇总 =====================
fails = [r for r in RESULTS if not r[1]]
print('\nSUMMARY: %d/%d passed, %d failed' % (len(RESULTS) - len(fails), len(RESULTS), len(fails)))
for name, ok, detail in fails:
    print('  FAILED: ' + name + (('  — ' + detail) if detail else ''))
sys.exit(0 if not fails else 1)