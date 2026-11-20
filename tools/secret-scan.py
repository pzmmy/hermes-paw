#!/usr/bin/env python3
"""secret-scan.py — 仓库凭据 / 内网 IP 扫描（S3 验收 c：零凭据、零内网 IP）。

扫描范围 = git ls-files（全部被跟踪文件）；二进制文件（含 NUL 字节）跳过。
命中类：
  CRED  真实 key 值（API_SERVER_KEY 环境变量取 16+ 真实字符，非占位符）
        / 私钥材料（BEGIN ... PRIVATE KEY）/ Bearer <16+ 字符 token>
        / hermespaw:// URI 内嵌 key 字段（16+ 字符）
  IP    真实内网段 10/8、172.16/12、192.168/16（占位写法 192.168.x.x 与
        文档段 192.0.2.0/24 不命中；每段校验 octet ≤ 255）
放行：同一行含 'secret-scan-allow' 注释标记的命中不计数（用于有意的文档示例）。
退出码：0 = 干净；1 = 有未放行命中。
用法：python3 tools/secret-scan.py [repo_root]
零第三方依赖（stdlib only）。

实现注意：双引号字面量里不写 `KEY=<token>` 形状——工具链脱敏会把它改写成
字面 ***（甚至吞掉闭合引号）致语法错（2026-11-16 踩过，写完须 od -c 验字节）。
故正则一律拆两段字面量拼接。
"""

import re
import subprocess
import sys
from pathlib import Path

CRED_PATTERNS = [
    ("API_KEY", re.compile(r"API_SERVER_KEY=" + r"([A-Za-z0-9+/=_\-]{16,})")),
    ("PRIVKEY", re.compile(r"BEGIN [A-Z ]*PRIVATE KEY")),
    ("BEARER", re.compile(r"Bearer " + r"([A-Za-z0-9._\-]{16,})")),
    ("SETUP_URI", re.compile(r"hermespaw://[^\s\"'<>]*?k=" + r"([A-Za-z0-9+/=]{16,})")),
]

# 分段写全：10/8 前缀 1 段 + 后 3 段；192.168/16 与 172.16/12 前缀 2 段 + 后 2 段。
# 不得共用后缀组（2026-11-16 负向自测抓到：共用组使 192.168.x.x 要 5 段、永不命中）。
IP_RE = re.compile(
    r"(?<![\d.])((?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|192\.168\.\d{1,3}\.\d{1,3}"
    r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})" + r"(?![\d.])" + r")"
)

PLACEHOLDERS = {
    "xxx", "xxxx", "placeholder", "changeme", "example", "your_key_here",
    "<key>", "your-key", "test", "dummy",
}


def is_real_value(val: str) -> bool:
    v = val.strip().strip("'\"")
    if len(v) < 16:
        return False
    if v.lower() in PLACEHOLDERS:
        return False
    # 全同一字符（****、xxxx...）视为占位
    if len(set(v)) == 1:
        return False
    return True


def mask(val: str) -> str:
    v = val.strip()
    return v[:4] + "…" + str(len(v)) + "chars"


def valid_ip(ip: str) -> bool:
    parts = ip.split(".")
    return len(parts) == 4 and all(p.isdigit() and int(p) <= 255 for p in parts)


def scan(root: Path):
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files"],
        capture_output=True, text=True, check=True,
    )
    files = [f for f in out.stdout.splitlines() if f.strip()]
    # 与 D4 发布边界对齐（见 tools/opensource-export.sh）：这三个目录已跟踪但
    # **不进开源包**，其中必然含内网 IP / 第三方参考源码；扫它们只会产生与发布
    # 无关的噪声（实测命中 docs/test-reports/*.md 与 opensource-research/*）。
    D4_EXCLUDED = ('evidence/', 'docs/test-reports/', 'docs/opensource-research/')
    files = [f for f in files if not f.startswith(D4_EXCLUDED)]
    hits = 0
    scanned = 0
    for rel in files:
        p = root / rel
        if not p.is_file():
            continue
        with p.open("rb") as fh:
            head = fh.read(8192)
        if b"\0" in head:
            continue  # binary
        scanned += 1
        text = p.read_text(encoding="utf-8", errors="ignore")
        for lineno, line in enumerate(text.splitlines(), 1):
            if "secret-scan-allow" in line:
                continue
            for name, pat in CRED_PATTERNS:
                m = pat.search(line)
                if not m:
                    continue
                if name == "PRIVKEY":
                    shown = m.group(0)
                else:
                    val = m.group(1)
                    if name == "API_KEY" and not is_real_value(val):
                        continue
                    shown = mask(val)
                print("HIT [CRED:" + name + "] " + rel + ":" + str(lineno) + ": " + shown)
                hits += 1
            m = IP_RE.search(line)
            if m and valid_ip(m.group(1)):
                print("HIT [IP] " + rel + ":" + str(lineno) + ": " + m.group(1))
                hits += 1
    status = "CLEAN" if hits == 0 else str(hits) + " HIT(S)"
    print("secret-scan: " + str(scanned) + " text files scanned, " + status)
    return 1 if hits else 0


def main() -> int:
    if len(sys.argv) > 1:
        root = Path(sys.argv[1]).resolve()
    else:
        root = Path(__file__).resolve().parent.parent
    if not (root / ".git").exists() and not (root / "tools").exists():
        print("secret-scan: " + str(root) + " 不像仓库根（无 .git / tools/）", file=sys.stderr)
        return 2
    return scan(root)


if __name__ == "__main__":
    sys.exit(main())
