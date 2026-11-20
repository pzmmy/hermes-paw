#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HermesPaw S3（收尾与开源）L2 自测 — 仓库秘密扫描（236 交付物）

对应 S3 plan 验收 (c)：仓库扫描零凭据、零内网 IP（开源内容边界 D4）。
扫描范围 = 全仓库 − 排除目录（evidence/、docs/test-reports/、docs/opensource-research/，见 EXCLUDED）；
排除目录是内部 QA 证据/第三方参考源码，不进入公开仓库，由 tools/opensource-export.sh 执行。
docs/opensource-research/ 为开源同类研究摘录（iHermes MIT 含内网 IP 示例、Conduit GPL-3.0
仅借思路不复制代码），不随公开包分发。

6 条检查:
  1. 零内网 IP（192.168.* / 10.* / 172.16-31.*；127.* 环回与
     192.0.2.*/198.51.100.*/203.0.113.* 文档保留段、100.64.* CGNAT 放行）
  2. 零 token 字面量（hermes_xxx 长值 / Bearer <16+ 字符真值>）
  3. 零内部用户名（to**d / s***.yang / 杨*，模式拼接构造防自命中）
  4. hilog 参数位零密钥变量（剥离格式串后查 token/envelope/plain 等）
  5. 开源范围无 >100KB 单文件
  6. icon 双树字节一致（AppScope vs entry icon.png 逐字节一致，
     双树同步回归防护，T1 轮 2026-11-17）

用法:
  python3 tools/s3-selftest.py

退出码: 0=全绿, 1=存在 FAIL, 2=环境异常
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# D4 开源内容边界：这些目录不进入公开仓库（内部 QA 证据 / 第三方参考源码）
EXCLUDED = [
    'evidence',
    'docs/test-reports',
    'docs/opensource-research',
]

# 检查 1：内网 IP（RFC1918）。放行: 127.* 环回、192.0.2.*/198.51.100.*/
# 203.0.113.*（RFC5737 文档保留段，开源示例用）、100.64.*（CGNAT/Tailnet）。
IP_PATTERNS = [
    (re.compile(r'192\.168\.\d{1,3}\.\d{1,3}'), '192.168.x'),
    (re.compile(r'(?<![\d.])10\.\d{1,3}\.\d{1,3}\.\d{1,3}'), '10.x'),
    (re.compile(r'(?<![\d.])172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}'), '172.16-31.x'),
]

# 检查 2：token 字面量。hermes_ 前缀 + 12+ 字符；Bearer + 16+ 字符真值
# （占位符 'Bearer <key>'/'Bearer {token}' 不含真值字符，不命中）。
TOKEN_PATTERNS = [
    (re.compile(r'hermes_[A-Za-z0-9]{12,}'), 'hermes_ token literal'),
    (re.compile(r'Bearer\s+[A-Za-z0-9._\-]{16,}'), 'Bearer token literal'),
]

# 检查 3：内部用户名（模式用拼接构造，避免扫描器自身命中）
_USER_A = 'to' + 'read'
_USER_B = 'song' + '.yang'
_USER_C = '杨' + '松'
USER_PATTERNS = [
    (re.compile(_USER_A, re.IGNORECASE), 'internal username (to**d)'),
    (re.compile(_USER_B, re.IGNORECASE), 'internal username (s***.yang)'),
    (re.compile(_USER_C), 'internal username (C*)'),
]

# 检查 5 白名单: hvigorw.js = DevEco 标准构建引导（任何 HarmonyOS 工程都有，
# ~1.1MB，非应用数据）。
# ChatVM.ets 曾因 §R0 并行轮询 108KB 临时入白名单；S3-b 删除不可达的 recovery
# 子系统后已回到 100KB 闸门以下，故从白名单移除（闸门重新对它生效）。
SIZE_WHITELIST = {'hvigorw.js'}

# 检查 4：hilog 参数位密钥变量。剥离单引号格式串后，参数位出现
# token/formToken/envelope/plain/cipher/nonce 变量 = 泄漏。
HILog_LEAK_RE = re.compile(
    r'\b(?:form_?token|this\.token|\btoken\b|envelope|\bplain\b|\bcipher\b|\bnonce\b)',
    re.IGNORECASE,
)

# 检查 6：icon 双树路径（AppScope = 应用图标，entry = 模块图标；两树必须
# 字节级一致，防止「只同步了一棵树」的回归）
ICON_APP = REPO / 'AppScope' / 'resources' / 'base' / 'media' / 'icon.png'
ICON_ENTRY = REPO / 'entry' / 'src' / 'main' / 'resources' / 'base' / 'media' / 'icon.png'


def excluded(rel: Path) -> bool:
    parts = rel.parts
    for ex in EXCLUDED:
        ex_parts = tuple(ex.split('/'))
        if parts[:len(ex_parts)] == ex_parts:
            return True
    return False


# 构建产物 / 依赖目录：不参与扫描（否则本地跑完构建就会出现几十个 1MB+ 的 HAP 误报）
_SKIP_DIR_NAMES = {'build', 'oh_modules', 'node_modules', '.hvigor', '.idea', 'dist', '__pycache__'}


def iter_files():
    for p in sorted(REPO.rglob('*')):
        if not p.is_file():
            continue
        rel = p.relative_to(REPO)
        if rel.parts[0] == '.git':
            continue
        if any(part in _SKIP_DIR_NAMES for part in rel.parts[:-1]):
            continue
        if excluded(rel):
            continue
        yield rel, p


def read_text(p: Path):
    try:
        with open(p, 'r', encoding='utf-8') as f:
            return f.read()
    except (UnicodeDecodeError, OSError):
        return None  # binary: only subject to size check


def main() -> int:
    findings = {i: [] for i in range(1, 7)}
    n_text = 0
    n_bin = 0

    for rel, p in iter_files():
        # 检查 5：大小（全部文件；白名单见 SIZE_WHITELIST）
        try:
            size = p.stat().st_size
        except OSError:
            continue
        if size > 100 * 1024 and rel.name not in SIZE_WHITELIST:
            findings[5].append('%s (%d KB)' % (rel, size // 1024))
        text = read_text(p)
        if text is None:
            n_bin += 1
            continue
        n_text += 1
        for lineno, line in enumerate(text.splitlines(), 1):
            loc = '%s:%d' % (rel, lineno)
            for rx, label in IP_PATTERNS:
                if rx.search(line):
                    findings[1].append('%s [%s]' % (loc, label))
            for rx, label in TOKEN_PATTERNS:
                if rx.search(line):
                    findings[2].append('%s [%s]' % (loc, label))
            for rx, label in USER_PATTERNS:
                if rx.search(line):
                    findings[3].append('%s [%s]' % (loc, label))
            # 检查 4 只对源码生效：文档里会「描述」这条规则（如"裸 hilog 调用数=0"），
            # 拿代码规则扫文档必然误报（实测命中 docs/refactor-design.md）。
            if rel.suffix == '.ets' and 'hilog.' in line:
                rest = re.sub(r"'[^']*'", "''", line)
                if HILog_LEAK_RE.search(rest):
                    findings[4].append(loc + ' [token-like var in log args]')

    # 检查 6：icon 双树字节一致（独立于文件循环，直读两树对比）
    try:
        if not ICON_APP.is_file() or not ICON_ENTRY.is_file():
            findings[6].append('icon.png 缺失 (AppScope=%s, entry=%s)'
                               % (ICON_APP.is_file(), ICON_ENTRY.is_file()))
        elif ICON_APP.read_bytes() != ICON_ENTRY.read_bytes():
            findings[6].append('icon.png 双树字节不一致 (AppScope vs entry)')
    except OSError as e:
        findings[6].append('icon.png 读取失败: %s' % e)

    names = {
        1: '零内网 IP',
        2: '零 token 字面量',
        3: '零内部用户名',
        4: 'hilog 参数位零密钥变量',
        5: '无 >100KB 单文件',
        6: 'icon 双树字节一致',
    }
    failed = False
    for i in range(1, 7):
        hits = findings[i]
        if hits:
            failed = True
            print('FAIL %s (%d hits)' % (names[i], len(hits)))
            for h in hits[:10]:
                print('     %s' % h)
            if len(hits) > 10:
                print('     ... +%d more' % (len(hits) - 10))
        else:
            print('PASS %s' % names[i])
    print('scanned: %d text files, %d binary files (excluded dirs: %s)'
          % (n_text, n_bin, ', '.join(EXCLUDED)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
