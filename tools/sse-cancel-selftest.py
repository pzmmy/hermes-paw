#!/usr/bin/env python3
"""S5a gate: SSE stream cancel self-test.

背景（模拟器实测两次复现）：
    19:25:34  ChatVM: finalize how=completed finalLength=792
    19:25:58  ChatVM: stream error: kind=stream_drop code=-2 SSE idle timeout

finalizeRun 已调 destroyStream()，但 23s 后又冒 idle timeout。根因：空闲看门狗
（terminated / idleTimerId）活在 ApiClient.openStream 的 Promise 闭包里，
ChatVM 只持有 http.HttpRequest 并 req.destroy()——清不掉已 arm 的 JS 定时器。

本门禁静态校验修复结构（7 条，第 7 条是反向对照：把 ChatVM 调用改回
req.destroy() 后第 6 条必须变红，证门禁不是恒绿）。

零依赖（仅 stdlib）。相对路径（repo 根 = 本文件父目录），任意 checkout 可跑。
输出：[PASS]/[FAIL] 编号 说明，末尾 "N checks, X PASS, Y FAIL"；rc=0 为绿。
"""
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ETS = ROOT / "entry" / "src" / "main" / "ets"
API = ETS / "net" / "ApiClient.ets"
RUNS = ETS / "net" / "RunsApi.ets"
CHAT = ETS / "viewmodel" / "ChatVM.ets"

_results = []


def check(num, ok, desc, detail=""):
    """记录一条检查结果。"""
    _results.append((num, bool(ok), desc, detail))
    if ok:
        print("[PASS] %s %s" % (num, desc))
    else:
        print("[FAIL] %s %s%s" % (num, desc, (" — " + detail) if detail else ""))
    return bool(ok)


def strip_comments(src):
    """剥离块注释与整行 // 注释（用于结构断言时不误伤说明文字）。"""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("//"))


def method_body(src, signature_re):
    """按花括号配对提取方法体（signature 首次匹配处）。找不到返回 None。"""
    m = re.search(signature_re, src)
    if not m:
        return None
    start = src.find("{", m.end() - 1)
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(src)):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start + 1:i]
    return None


def read(path):
    """读文件；缺失返回 None（门禁后续按 FAIL 处理，不抛栈）。"""
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8")


def chatvm_ok(chat_src):
    """第 6 条的本体：destroyStream 内走 cancelEvents 且不再 req.destroy()。"""
    if chat_src is None:
        return False, "ChatVM.ets 不存在"
    body = method_body(strip_comments(chat_src), r"private\s+destroyStream\s*\(\s*\)\s*:\s*void")
    if body is None:
        return False, "未找到 destroyStream 方法体"
    if "this.runs.cancelEvents(" not in body:
        return False, "destroyStream 未调用 this.runs.cancelEvents("
    if re.search(r"\breq\s*\.\s*destroy\s*\(", body):
        return False, "destroyStream 仍残留 req.destroy()"
    return True, ""


def main():
    print("=== S5a SSE cancel self-test (ApiClient 闭包看门狗 / RunsApi 透传 / ChatVM 收口) ===")
    api = read(API)
    runs = read(RUNS)
    chat = read(CHAT)

    # 1) ApiClient 登记表字段
    if api is None:
        check(1, False, "ApiClient.ets 存在且含 streamCancelers Map 字段", "文件缺失")
    else:
        src = strip_comments(api)
        ok = re.search(
            r"streamCancelers\s*:\s*Map\s*<\s*http\.HttpRequest\s*,\s*\(\s*\)\s*=>\s*void\s*>",
            src) is not None
        check(1, ok, "ApiClient.ets 含 streamCancelers: Map<http.HttpRequest, () => void> 字段")

    # 2) openStream 内登记
    if api is None:
        check(2, False, "openStream 内登记 streamCancelers.set(req, ...)", "文件缺失")
    else:
        src = strip_comments(api)
        body = method_body(src, r"openStream\s*\([^)]*\)\s*:\s*Promise\s*<")
        if body is None:
            check(2, False, "openStream 内登记 streamCancelers.set(req, ...)", "未找到 openStream 方法体")
        else:
            ok = "this.streamCancelers.set(req," in re.sub(r"\s+", " ", body) or \
                 re.search(r"this\.streamCancelers\.set\(\s*req\s*,", body) is not None
            check(2, ok, "openStream 内登记 streamCancelers.set(req, ...)")

    # 3) 两条终态路径都撤登记
    if api is None:
        check(3, False, "finishError 与 dataEnd 都 streamCancelers.delete(req)", "文件缺失")
    else:
        src = strip_comments(api)
        fe = method_body(src, r"const\s+finishError\s*=\s*\(")
        de = method_body(src, r"req\.on\(\s*'dataEnd'\s*,")
        if fe is None or de is None:
            check(3, False, "finishError 与 dataEnd 都 streamCancelers.delete(req)",
                  "未找到 finishError(%s) / dataEnd(%s)" % (fe is not None, de is not None))
        else:
            ok_fe = re.search(r"this\.streamCancelers\.delete\(\s*req\s*\)", fe) is not None
            ok_de = re.search(r"this\.streamCancelers\.delete\(\s*req\s*\)", de) is not None
            check(3, ok_fe and ok_de, "finishError 与 dataEnd 都 streamCancelers.delete(req)",
                  "finishError=%s dataEnd=%s" % (ok_fe, ok_de))

    # 4) cancelStream 方法定义 + 取消路径真的走到闭包内的置位动作。
    #    terminated / idleTimerId 活在 openStream 的 Promise 闭包里，类方法碰不到；
    #    所以断言的「取消路径」= cancelStream 本体（取登记 + 调用）∪ openStream
    #    内那段登记闭包（terminated = true + clearIdle() + doDestroy）。两者缺一
    #    都意味着看门狗没被停掉，故合并成一条检查（严格强于只查方法体文本）。
    if api is None:
        check(4, False, "ApiClient 有 cancelStream() 且取消路径含 terminated = true 与 clearIdle()", "文件缺失")
    else:
        src = strip_comments(api)
        body = method_body(src, r"cancelStream\s*\(\s*req\s*:\s*http\.HttpRequest\s*\|\s*null\s*\)\s*:\s*void")
        if body is None:
            check(4, False, "ApiClient 有 cancelStream() 且取消路径含 terminated = true 与 clearIdle()",
                  "未找到 cancelStream 方法定义")
        else:
            has_get = re.search(r"this\.streamCancelers\.get\(\s*req\s*\)", body) is not None
            has_call = re.search(r"\bcancel\s*\(\s*\)", body) is not None
            reg = method_body(src, r"this\.streamCancelers\.set\(\s*req\s*,")
            has_term = reg is not None and re.search(r"\bterminated\s*=\s*true\b", reg) is not None
            has_clear = reg is not None and re.search(r"\bclearIdle\s*\(\s*\)", reg) is not None
            check(4, has_get and has_call and has_term and has_clear,
                  "ApiClient 有 cancelStream() 且取消路径含 terminated = true 与 clearIdle()",
                  "get=%s call=%s terminated=%s clearIdle=%s"
                  % (has_get, has_call, has_term, has_clear))

    # 5) RunsApi 透传层
    if runs is None:
        check(5, False, "RunsApi 有 cancelEvents() 且调用 this.client.cancelStream(", "文件缺失")
    else:
        src = strip_comments(runs)
        body = method_body(src, r"cancelEvents\s*\(\s*req\s*:\s*http\.HttpRequest\s*\|\s*null\s*\)\s*:\s*void")
        if body is None:
            check(5, False, "RunsApi 有 cancelEvents() 且调用 this.client.cancelStream(", "未找到 cancelEvents")
        else:
            ok = re.search(r"this\.client\.cancelStream\(", body) is not None
            check(5, ok, "RunsApi 有 cancelEvents() 且调用 this.client.cancelStream(")

    # 6) ChatVM 收口改道（真实源文件）
    ok6, why6 = chatvm_ok(chat)
    check(6, ok6, "ChatVM.destroyStream 调用 this.runs.cancelEvents( 且无 req.destroy()", why6)

    # 7) 反向对照：临时副本回退成 req.destroy()，第 6 条必须变红
    if chat is None:
        check(7, False, "反向对照：回退 cancelEvents→req.destroy() 后第 6 条变红", "ChatVM.ets 缺失")
    else:
        tmp = Path(tempfile.mkdtemp(prefix="s5a-ctrl-"))
        try:
            copy = tmp / "ChatVM.ets"
            shutil.copyfile(CHAT, copy)
            orig = copy.read_text(encoding="utf-8")
            mutated = orig.replace("this.runs.cancelEvents(req);", "req.destroy();")
            if mutated == orig:
                check(7, False, "反向对照：回退 cancelEvents→req.destroy() 后第 6 条变红",
                      "副本中未找到 this.runs.cancelEvents(req); 无法构造对照")
            else:
                copy.write_text(mutated, encoding="utf-8")
                ok_mut, _ = chatvm_ok(mutated)
                check(7, not ok_mut, "反向对照：回退 cancelEvents→req.destroy() 后第 6 条变红",
                      "回退后第 6 条仍为绿（门禁恒绿，无效）")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    total = len(_results)
    passed = sum(1 for r in _results if r[1])
    failed = total - passed
    print("%d checks, %d PASS, %d FAIL" % (total, passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())