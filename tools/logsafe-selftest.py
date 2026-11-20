#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""logsafe-selftest.py — S4b LogSafe 门禁。

只做静态文本核验（不需要 DevEco / 不编译 app）：证明
  1) LogSafe.ets 这道唯一出口本身完整（4 级别 + mask + DOMAIN）；
  2) mask 的敏感词表没被人删词；
  3) 全仓唯一 import 真 hilog 的地方就是 LogSafe.ets；
  4) 本批共 21 个文件（S4b-1 ~ S4b-6）已零裸 hilog（S4b 已收尾）；
  5) 冻结清单已清空（FROZEN = {}，FROZEN_TOTAL = 0），因此本条校验的是
     S4b 终态：全仓裸 hilog. 必须为 0。若将来又有文件被临时冻结，条目照旧
     逐文件精确相等（减少也算回归）；
  6) LogSafe 真的还在打日志（4 个方法各转发一次），不是空壳；
  7) 转发时 fmt 本体不许套 mask()（fmt 里只有 %{public}d 之类占位符，
     对 fmt 做正则既无意义又会在调用方传常量拼接串时改语义）。

关于 #3 与 #5 的关系（S4b 收尾后两者都指向终态）：S4b-1 ~ S4b-6 累计迁 179 处
（S4b-1 9 + S4b-2 16 + S4b-3 33 + S4b-4 28 + S4b-5 20 + S4b-6 73），冻结清单已清空，
故 #3 的口径就是终态「全仓出现 hilog. 的文件集 == {utils/LogSafe.ets}」——即 hilog
这个符号只允许从 LogSafe.ets 进来；谁在别处 import 或直接调用 hilog，#3 立刻变红。
#5 在本批从「逐文件冻结计数」退化为同一终态的条数校验（全仓裸 hilog. = 0），
若清单日后重新填入条目，仍按逐文件精确相等执行（多一处、少一处都红）。

脚本输出：[PASS]/[FAIL] 编号 说明，末尾 "N checks, X PASS, Y FAIL"。
退出码 0 = 全绿。

零依赖（仅 stdlib）。
"""
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # 仓根（tools/ 的上一级）
ETS = os.path.join(ROOT, 'entry/src/main/ets')

LOGSF = 'utils/LogSafe.ets'

# 本批必须归零的文件（S4b-1 4 + S4b-2 5 + S4b-3 2 + S4b-4 8 + S4b-5 1 + S4b-6 1 = 21 个）
BATCH = [
    'entryability/EntryAbility.ets',
    'pages/AboutPage.ets',
    'pages/OnboardPage.ets',
    'model/Run.ets',
    'media/PhotoPick.ets',
    'net/SseParser.ets',
    'pages/LoginPage.ets',
    'model/ChatMessage.ets',
    'store/AuthSession.ets',
    'store/DbHelper.ets',
    'pages/SettingsPage.ets',
    'pages/ChatPage.ets',
    'store/TokenVault.ets',
    'net/ApiClient.ets',
    'net/SessionsApi.ets',
    'theme/Accent.ets',
    'viewmodel/LoginVM.ets',
    'viewmodel/ScanVM.ets',
    'pages/ScanPage.ets',
    'viewmodel/SettingsVM.ets',
    'viewmodel/ChatVM.ets',
]

# #5 冻结清单：未迁文件的裸 hilog 计数，精确相等。
# S4b-6 已把最后一个文件（ChatVM 73 处）迁完，清单清空 -> 全仓终态。
FROZEN = {}
FROZEN_TOTAL = 0

RE_HILOG_ANY = re.compile(r'hilog\.')
RE_HILOG_IMPORT = re.compile(
    r"import\s*\{[^}]*\bhilog\b[^}]*\}\s*from\s*['\"]@kit\.PerformanceAnalysisKit['\"]")
RE_FMT_MASKED = re.compile(r'mask\(\s*fmt\s*\)')

CALL_LEVELS = ('debug', 'info', 'warn', 'error')


# ---------------------------------------------------------------- helpers
def read(path):
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def ets_path(ets_dir, rel):
    return os.path.join(ets_dir, rel)


def count_calls(ets_dir, rel):
    """裸 hilog. 出现次数；文件不存在返回 None。"""
    p = ets_path(ets_dir, rel)
    if not os.path.isfile(p):
        return None
    return len(RE_HILOG_ANY.findall(read(p)))


def walk_files(ets_root, exts=('.ets', '.ts')):
    for dirpath, dirnames, filenames in os.walk(ets_root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules', 'build')]
        for fn in filenames:
            if fn.endswith(exts):
                yield os.path.join(dirpath, fn)


# --------------------------------------------------------------- checks
def check01(ets_dir):
    """LogSafe.ets 存在，含 d/i/w/e/mask 与 DOMAIN。"""
    p = ets_path(ets_dir, LOGSF)
    if not os.path.isfile(p):
        return False, '%s 不存在' % LOGSF
    src = read(p)
    missing = []
    for name in ('d', 'i', 'w', 'e'):
        if not re.search(r'static\s+%s\s*\(' % name, src):
            missing.append('static %s(' % name)
    if not re.search(r'static\s+mask\s*\(', src):
        missing.append('static mask(')
    if 'DOMAIN' not in src:
        missing.append('DOMAIN')
    if missing:
        return False, '缺: ' + ', '.join(missing)
    return True, 'LogSafe.ets 齐备（d/i/w/e/mask/DOMAIN）'


def check02(ets_dir):
    """mask 的敏感词表 5 个关键词全在。"""
    p = ets_path(ets_dir, LOGSF)
    if not os.path.isfile(p):
        return False, '%s 不存在' % LOGSF
    src = read(p)
    # 词表必须落在 RE_KV（mask 规则1）里
    m = re.search(r'RE_KV[^;]*;', src, re.S)
    scope = m.group(0) if m else ''
    words = ('key', 'token', 'authorization', 'password', 'secret')
    miss = [w for w in words if w not in scope.lower()]
    if miss:
        return False, 'RE_KV 缺词: ' + ', '.join(miss)
    return True, 'RE_KV 词表完整（key|token|authorization|password|secret）'


def check03(ets_dir):
    """全仓出现 hilog. 的**文件集合**必须精确等于 {LogSafe.ets} ∪ 冻结清单。

    S4b-6 之后冻结清单为空，本条即终态断言：
      全仓出现 hilog. 的文件集 == {utils/LogSafe.ets}（不多、不少）。
    与 #5 互补：#3 抓「多/少一个文件」，#5 抓「同文件内多/少一处」。
    清单非空时（历史上 S4b-1 ~ S4b-5 期间）同一段代码照旧按
    {LogSafe.ets} ∪ FROZEN 求等式，无需改 #3。
    """
    hits = set()
    for path in walk_files(ets_dir):
        if RE_HILOG_ANY.search(read(path)):
            hits.add(os.path.relpath(path, ets_dir).replace(os.sep, '/'))

    expect = set(FROZEN) | {LOGSF}
    batch_dirty = set(BATCH) & hits
    extra = hits - expect
    gone = expect - hits
    problems = []
    if batch_dirty:
        problems.append('本批仍有裸 hilog: ' + ', '.join(sorted(batch_dirty)))
    if extra:
        problems.append('清单外文件出现 hilog.: ' + ', '.join(sorted(extra)))
    if gone:
        problems.append('清单内文件已无 hilog.（提前迁了，需同步清单）: ' + ', '.join(sorted(gone)))
    if problems:
        return False, '; '.join(problems)
    if not FROZEN:
        return True, '出现 hilog. 的文件集精确等于 {%s}（终态，冻结清单为空）' % LOGSF
    return True, '出现 hilog. 的文件 = %s + %d 个冻结文件，精确相等' % (LOGSF, len(FROZEN))


def check04(ets_dir):
    """本批（BATCH）全部文件裸 hilog 计数 = 0。"""
    bad = []
    for rel in BATCH:
        n = count_calls(ets_dir, rel)
        if n is None:
            bad.append('%s(缺失)' % rel)
        elif n != 0:
            bad.append('%s=%d' % (rel, n))
    if bad:
        return False, '仍有裸 hilog: ' + ', '.join(bad)
    return True, '本批 %d 文件裸 hilog 均为 0' % len(BATCH)


def check05(ets_dir):
    """冻结清单精确相等；清单为空时退化为 S4b 终态断言（全仓裸 hilog. = 0）。

    空清单下不能退化成「0 个文件、合计 0，恒真」的空断言——那等于关掉这道门。
    所以 FROZEN == {} 时改判终态：除 utils/LogSafe.ets 外全仓裸 hilog. 合计
    必须等于 FROZEN_TOTAL(0)。清单非空时仍逐文件精确相等（减少也算回归）。
    """
    if not FROZEN:
        offenders = {}
        total = 0
        for path in walk_files(ets_dir):
            rel = os.path.relpath(path, ets_dir).replace(os.sep, '/')
            if rel == LOGSF:                       # 唯一允许出现 hilog. 的文件
                continue
            n = len(RE_HILOG_ANY.findall(read(path)))
            if n:
                offenders[rel] = n
                total += n
        if total != FROZEN_TOTAL:
            detail = ', '.join('%s=%d' % kv for kv in sorted(offenders.items())) or '无'
            return False, '终态破防: 全仓裸 hilog. 合计 %d != %d（%s）' % (total, FROZEN_TOTAL, detail)
        return True, '终态：冻结清单为空，全仓除 %s 外裸 hilog. 合计 %d' % (LOGSF, total)

    bad = []
    total = 0
    for rel, want in FROZEN.items():
        got = count_calls(ets_dir, rel)
        if got is None:
            bad.append('%s: 缺失(期望 %d)' % (rel, want))
            continue
        total += got
        if got != want:
            bad.append('%s: %d != %d' % (rel, got, want))
    if total != FROZEN_TOTAL:
        bad.append('合计 %d != %d' % (total, FROZEN_TOTAL))
    if bad:
        return False, '冻结清单破防: ' + '; '.join(bad)
    return True, '%d 文件精确相等，合计 %d 处冻结' % (len(FROZEN), total)


def check06(ets_dir):
    """LogSafe 内部真调 4 个 hilog 方法，各 1 处。"""
    p = ets_path(ets_dir, LOGSF)
    if not os.path.isfile(p):
        return False, '%s 不存在' % LOGSF
    src = read(p)
    bad = []
    for lvl in CALL_LEVELS:
        n = len(re.findall(r'hilog\.%s\s*\(' % lvl, src))
        if n != 1:
            bad.append('hilog.%s x%d' % (lvl, n))
    if bad:
        return False, '转发不完整: ' + ', '.join(bad)
    return True, 'hilog.debug/info/warn/error 各 1 处转发'


def check07(ets_dir):
    """转发语句里 fmt 未套 mask(。"""
    p = ets_path(ets_dir, LOGSF)
    if not os.path.isfile(p):
        return False, '%s 不存在' % LOGSF
    src = read(p)
    if RE_FMT_MASKED.search(src):
        return False, '发现 mask(fmt) —— fmt 被掩码，语义被改'
    if re.search(r'LogSafe\.mask\(\s*fmt', src):
        return False, '发现调用侧 mask(fmt)'
    return True, '4 条转发均直传 fmt（未套 mask）'


def check08(ets_dir):
    """反向对照：AboutPage 塞回一行 hilog.info( -> check04 必须变红。"""
    tmp = tempfile.mkdtemp(prefix='logsafe-rc8-')
    try:
        work = os.path.join(tmp, 'ets')
        shutil.copytree(ets_dir, work)
        p = ets_path(work, 'pages/AboutPage.ets')
        src = read(p)
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(src + "\nfunction __rc8(): void {\n"
                         "  hilog.info(0x0001, TAG, 'rc8');\n}\n")
        injected = count_calls(work, 'pages/AboutPage.ets')
        ok4, msg4 = check04(work)
        if injected != 1:
            return False, '注入失败（计数 %s），对照无效' % injected
        if ok4:
            return False, '注入 1 处裸 hilog 后 #4 仍绿 —— #4 是空断言'
        return True, '注入后 AboutPage=1，#4 如期变红（%s）' % msg4
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check09(ets_dir):
    """反向对照 #5：往 ChatVM 里塞回 1 处裸 hilog -> check05 必须变红。

    S4b-6 之后 FROZEN 为空，空清单下 check05 若写成「遍历 0 个文件、合计 0」，
    就退化成恒真空断言。所以对照方式从「偷迁一处（73->72）」改成「回退一处
    （0->1）」：ChatVM 塞回一条裸 hilog.debug 后，终态合计 1 != 0，必须变红。
    """
    tmp = tempfile.mkdtemp(prefix='logsafe-rc9-')
    try:
        work = os.path.join(tmp, 'ets')
        shutil.copytree(ets_dir, work)
        p = ets_path(work, 'viewmodel/ChatVM.ets')
        src = read(p)
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(src + "\nfunction __rc9(): void {\n"
                         "  hilog.debug(DOMAIN, TAG, 'rc9');\n}\n")
        got = count_calls(work, 'viewmodel/ChatVM.ets')
        ok5, msg5 = check05(work)
        if got != 1:
            return False, '塞回后计数 %s != 1，对照无效' % got
        if ok5:
            return False, 'ChatVM 塞回 1 处裸 hilog 后 #5 仍绿 —— 空清单退化成空断言'
        return True, 'ChatVM=1，#5 如期变红（%s）' % msg5
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def logsafe_members(ets_dir):
    """LogSafe.ets 里声明过的 static 成员名集合。"""
    p = ets_path(ets_dir, LOGSF)
    if not os.path.isfile(p):
        return set()
    txt = read(p)
    return set(re.findall(r'\bstatic\s+(?:readonly\s+)?([A-Za-z_]\w*)\s*[:\(]', txt))


RE_LOGSF_USE = re.compile(r'\bLogSafe\.([A-Za-z_]\w*)')


def check10(ets_dir):
    """全仓 LogSafe.<x> 的 x 必须都在 LogSafe.ets 里声明过。

    这条是唯一能抓住「调用了不存在的方法」的静态检查：arkts-lint 是自定义
    规则集，不做类型解析；logsafe 前 9 条只看 hilog 计数。历史上真出现过交付
    版写成 LogSafe.debug/info/warn（实际只有 d/i/w/e）而 lint 全绿的情况。
    """
    declared = logsafe_members(ets_dir)
    if not declared:
        return False, '读不到 LogSafe.ets 声明'
    bad = {}
    for path in walk_files(ets_dir):
        txt = read(path)
        for name in RE_LOGSF_USE.findall(txt):
            if name not in declared:
                rel = os.path.relpath(path, ets_dir)
                bad.setdefault('%s()' % name, []).append(rel)
    if bad:
        detail = '; '.join('%s ← %s' % (k, ','.join(sorted(set(v))[:2])) for k, v in sorted(bad.items()))
        return False, '调用了 LogSafe 未声明成员：%s（已声明 %s）' % (
            detail, '/'.join(sorted(declared)))
    return True, '全仓 %d 个 LogSafe 成员引用均已在声明中' % len(declared)


def check11(ets_dir):
    """反向对照：把一处 LogSafe.d 改成 LogSafe.debug -> check10 必须变红。"""
    tmp = tempfile.mkdtemp(prefix='logsafe-rc11-')
    try:
        work = os.path.join(tmp, 'ets')
        shutil.copytree(ets_dir, work)
        p = ets_path(work, 'store/DbHelper.ets')
        txt = read(p)
        if 'LogSafe.d(' not in txt:
            return False, 'DbHelper 里没有 LogSafe.d(，对照无效'
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(txt.replace('LogSafe.d(', 'LogSafe.debug(', 1))
        ok10, msg10 = check10(work)
        if ok10:
            return False, '改成 LogSafe.debug( 后 #10 仍绿 —— 成员校验没生效'
        return True, '#10 如期变红（%s）' % msg10[:52]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


CHECKS = [
    ('01', 'LogSafe.ets 存在且含 d/i/w/e/mask/DOMAIN', check01),
    ('02', 'mask 敏感词表 5 词齐全', check02),
    ('03', '出现 hilog. 的文件集 = LogSafe.ets + 冻结清单（精确相等）', check03),
    ('04', '本批 %d 文件裸 hilog = 0' % len(BATCH), check04),
    ('05', '冻结清单精确相等 / 空清单即全仓终态（合计 %d）' % FROZEN_TOTAL, check05),
    ('06', 'LogSafe 转发真 hilog 各 1 处', check06),
    ('07', '转发语句 fmt 未套 mask(', check07),
    ('08', '反向对照 #4：注入裸 hilog 必红', check08),
    ('09', '反向对照 #5：回退一处裸 hilog 必红', check09),
    ('10', '全仓 LogSafe.X 的 X 均已在 LogSafe.ets 声明', check10),
    ('11', '反向对照 #10：改成未声明成员必红', check11),
]


def main():
    if not os.path.isdir(ETS):
        print('[FAIL] 00 找不到 %s（cwd 不对？）' % ETS)
        print('0 checks, 0 PASS, 1 FAIL')
        return 1

    print('logsafe-selftest  root=%s' % ROOT)
    print('-' * 68)
    passed = failed = 0
    for num, title, fn in CHECKS:
        try:
            ok, detail = fn(ETS)
        except Exception as exc:                       # 断言自身炸掉也算红
            ok, detail = False, '断言异常: %r' % (exc,)
        if ok:
            passed += 1
        else:
            failed += 1
        print('[%s] %s %s' % ('PASS' if ok else 'FAIL', num, title))
        print('       %s' % detail)
    print('-' * 68)
    total = passed + failed
    print('%d checks, %d PASS, %d FAIL' % (total, passed, failed))
    if failed:
        print('RESULT: FAIL')
        return 1
    print('RESULT: ALL GREEN')
    return 0


if __name__ == '__main__':
    sys.exit(main())