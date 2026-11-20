#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HermesPaw S2-a（图片输入）L2 自测 — 客户端逻辑等价 Python 复刻（236 交付物）

复刻对象（与 .ets 源码保持同构，改动须同步）:
  model/Multimodal.ets — buildUserMessage / 限额常量
  media/PhotoPick.ets  — 读字节 → 长边 resize 1568 → JPEG q80 → base64 data URL
                         （滤镜差异: PIL LANCZOS vs ArkUI image.resize，记录为
                          复刻差异，不影响契约验证）
  net/RunsApi.ets      — POST /v1/runs body {input, session_id}

输出规范（同 tools/api-selftest.py §8.1）: 只打印 用例名 + PASS/FAIL + 端点；
不打印 key；证据包内图片 base64 截断。

用法:
  python3 tools/s2-selftest.py [--base http://127.0.0.1:8377] [--photo PATH]

退出码: 0=全绿, 1=存在 FAIL, 2=环境异常
"""
import argparse
import base64
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = "http://127.0.0.1:8377"
SESSION_KEY = "hermes...test"
TERMINAL = {"completed", "failed", "cancelled", "interrupted"}
EVID_DIR = Path(__file__).resolve().parent.parent / "evidence"
EVID = EVID_DIR / ("s2-selftest-%s.jsonl" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
RESULTS = []

# --- 客户端常量（mirror of entry/src/main/ets/model/Multimodal.ets）---
MM_MAX_IMAGES = 10
MM_MAX_RAW_BYTES = 20 * 1024 * 1024
MM_MAX_B64_CHARS = 50 * 1024 * 1024
MM_TARGET_LONG_EDGE = 1568
JPEG_QUALITY = 80


def load_key():
    try:
        p = Path.home() / ".hermes" / ".env"
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line.startswith("API_SERVER_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return os.environ.get("API_SERVER_KEY", "")


key = load_key()

_SENS = re.compile(r"(key|token|secret|password|authorization|credential)", re.I)
_B64 = re.compile(r"(base64,)[A-Za-z0-9+/=]{80,}")


def redact_text(raw, limit=800):
    """响应体首段脱敏 + base64 数据截断（证据包不得含整图）。"""
    if not raw:
        return ""
    raw = _B64.sub(lambda m: m.group(1) + m.group(0).split(",", 1)[1][:64]
                   + "...[B64 TRUNC %d chars]" % (len(m.group(0)) - 72), raw)
    return raw[:limit]


def ev(case, method, path, status, note=""):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "case": case, "req": "%s %s" % (method, path), "status": status}
    if note:
        rec["note"] = note[:2000]
    with open(EVID, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def http(method, path, body=None, headers=None, timeout=300, case="?"):
    h = dict(headers or {})
    # 脱敏安全模式: 小写变量拼接（工具管道会破坏 Bearer+大写变量写法）
    h["Authorization"] = 'Bearer ' + key
    h["User-Agent"] = "hermes-paw-s2-selftest/1.0"
    data = json.dumps(body).encode() if body is not None else None
    if data is not None:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status = r.status
            raw = r.read(500000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status = e.code
        raw = e.read(500000).decode("utf-8", "replace")
    except Exception as e:
        ev(case, method, path, 0, "transport: %s" % type(e).__name__)
        return 0, None
    ev(case, method, path, status, redact_text(raw))
    try:
        return status, (json.loads(raw) if raw else None)
    except Exception:
        return status, None


def check(case_id, name, endpoint, ok, detail=""):
    RESULTS.append((case_id, name, endpoint, "PASS" if ok else "FAIL", detail))
    print("[%s] %s %s %s" % ("PASS" if ok else "FAIL", case_id, name, endpoint))
    if detail:
        print("       %s" % detail[:300])


# --- Multimodal 复刻（model/Multimodal.ets）---

def text_part(text):
    return {"type": "text", "text": text}


def image_url_part(data_url):
    return {"type": "image_url", "image_url": {"url": data_url}}


def build_user_message(text, data_urls):
    if not data_urls:
        return []
    content = []
    if text:
        content.append(text_part(text))
    for u in data_urls:
        content.append(image_url_part(u))
    return [{"role": "user", "content": content}]


# --- PhotoPick 复刻（media/PhotoPick.ets，PIL 实现）---

def prepare_image(path):
    from PIL import Image
    data = Path(path).read_bytes()
    if len(data) > MM_MAX_RAW_BYTES:
        raise ValueError("raw too large: %d" % len(data))
    img = Image.open(io.BytesIO(data))
    img.load()
    w, h = img.size
    long_edge = max(w, h)
    if long_edge > MM_TARGET_LONG_EDGE:
        scale = MM_TARGET_LONG_EDGE / long_edge
        img = img.resize((max(1, round(w * scale)), max(1, round(h * scale))))
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=JPEG_QUALITY)
    jpeg = buf.getvalue()
    b64 = base64.b64encode(jpeg).decode("ascii")
    if len(b64) > MM_MAX_B64_CHARS:
        raise ValueError("b64 too large: %d" % len(b64))
    return {"uri": str(path), "dataUrl": "data:image/jpeg;base64," + b64,
            "bytes": len(jpeg), "orig": "%dx%d" % (w, h)}


# --- session / run helpers（net/*Api.ets 端点）---

def create_session(title):
    st, d = http("POST", "/api/sessions", {"title": title},
                 headers={"X-Hermes-Session-Key": SESSION_KEY}, case="S2-session")
    sid = (d or {}).get("session", {}).get("id", "")
    return st, sid


def delete_session(sid, case="S2-cleanup"):
    st, _ = http("DELETE", "/api/sessions/%s" % sid, case=case)
    return st


def start_run(case, input_payload, sid, timeout=120):
    body = {"input": input_payload, "session_id": sid}
    h = {"X-Hermes-Session-Key": SESSION_KEY}
    st, d = http("POST", "/v1/runs", body, headers=h, timeout=timeout, case=case)
    run_id = (d or {}).get("run_id", "")
    return st, run_id, d


def wait_terminal(run_id, timeout=300, case="?"):
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        st, d = http("GET", "/v1/runs/%s" % run_id, case=case)
        if st == 200 and isinstance(d, dict):
            last = d
            if d.get("status") in TERMINAL:
                return d.get("status"), d
        time.sleep(2)
    return ("timeout", last)


def extract_reply(fin):
    """从 run 快照尽力取助手回复文本（多形态兜底）。"""
    if not isinstance(fin, dict):
        return ""
    out = fin.get("output")
    if isinstance(out, str) and out.strip():
        return out.strip()
    if isinstance(out, list):
        parts = []
        for m in out:
            if isinstance(m, dict) and m.get("role") == "assistant":
                c = m.get("content")
                if isinstance(c, str):
                    parts.append(c)
                elif isinstance(c, list):
                    for p in c:
                        if isinstance(p, dict) and p.get("type") == "text":
                            parts.append(p.get("text", ""))
        if parts:
            return "\n".join(parts)
    msgs = fin.get("messages")
    if isinstance(msgs, list):
        for m in reversed(msgs):
            if isinstance(m, dict) and m.get("role") == "assistant":
                c = m.get("content")
                if isinstance(c, str) and c.strip():
                    return c.strip()
    return ""


def err_code(d):
    try:
        return (d or {}).get("error", {}).get("code", "")
    except Exception:
        return ""


def main():
    global BASE
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=BASE)
    # Default: repo-bundled synthetic fixture (left red / right blue blocks),
    # so the self-test is reproducible out of the box (open-source friendly).
    ap.add_argument("--photo",
                    default=str(Path(__file__).resolve().parent
                                / "testdata" / "photo-sample.jpg"))
    a = ap.parse_args()
    BASE = a.base
    if not key:
        # 🟡-r3-2 closeout (170 审爷 r3): gateway-dependent selftest SKIPs (not FAILs)
        # when API_SERVER_KEY is absent (CI / 170 / fresh checkout). SKIP exit code 77
        # (make convention: untested); run-l2.sh maps rc=77 -> SKIP (non-failure).
        print("SKIP: API_SERVER_KEY 未配置（非 gateway 环境，gateway 自测跳过；236 侧实跑全绿）")
        sys.exit(77)
    EVID_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d%H%M%S")

    # L2-01 parts 构造同构（离线）
    m1 = build_user_message("图里有什么？", ["data:image/jpeg;base64,AAAA"])
    ok = (len(m1) == 1 and m1[0]["role"] == "user"
          and m1[0]["content"][0] == {"type": "text", "text": "图里有什么？"}
          and m1[0]["content"][1] == {"type": "image_url",
                                      "image_url": {"url": "data:image/jpeg;base64,AAAA"}})
    m2 = build_user_message("", ["u1", "u2"])
    ok = ok and (len(m2) == 1 and len(m2[0]["content"]) == 2
                 and all(p["type"] == "image_url" for p in m2[0]["content"]))
    m3 = build_user_message("no images", [])
    ok = ok and (m3 == [])
    check("L2-01", "parts 构造同构（text+image / image-only / 空→[]）", "local", ok,
          "shape: role=user content=[text?, image_url*]")

    # 真实照片准备（复刻 prepareImage 管线）
    try:
        prep = prepare_image(a.photo)
    except Exception as e:
        print("SELFTEST_ERROR: 照片准备失败: %s" % e)
        sys.exit(2)
    print("       photo=%s orig=%s jpeg=%dB b64_chars=%d"
          % (a.photo, prep["orig"], prep["bytes"], len(prep["dataUrl"])))

    st, sid = create_session("S2-selftest-%s" % ts)
    check("L2-00", "建独立测试会话", "/api/sessions", st == 201 and bool(sid))
    if not sid:
        sys.exit(2)

    try:
        # L2-04 / L2-06（快速 400 用例，先跑省总时长）
        inp4 = build_user_message("check", [prep["dataUrl"]] * 11)
        st4, _, d4 = start_run("L2-04", inp4, sid, timeout=60)
        check("L2-04", "11 图被拒（400, 服务端 _IMAGE_LIMIT=10）", "/v1/runs",
              st4 == 400, "status=%s code=%s" % (st4, err_code(d4)))

        # L2-06a: image/* 头但字节不是真图（魔数嗅探失败）→ 400 invalid_params
        # （服务端真实拒绝路径：commit_api_images 的 sniff_image_mime 兜底）
        bad_png = ("data:image/png;base64,"
                   + base64.b64encode(b"this is not a png image at all").decode("ascii"))
        inp6a = build_user_message("check", [bad_png])
        st6a, _, d6a = start_run("L2-06a", inp6a, sid, timeout=60)
        check("L2-06a", "image/* 头+坏字节被拒（400 invalid_params）", "/v1/runs",
              st6a == 400 and err_code(d6a) == "invalid_params",
              "status=%s code=%s" % (st6a, err_code(d6a)))

        # L2-06b: 非图片 data URL（text/plain）→ 202 透传（契约观察：
        # 服务端静默过滤出 commit 集、原样交模型处理；客户端恒发
        # image/jpeg，不会走到该路径，此用例锚定服务端当前行为）
        bad_url = "data:text/plain;base64," + base64.b64encode(b"hello").decode("ascii")
        inp6 = build_user_message("check", [bad_url])
        st6, rid6, _ = start_run("L2-06b", inp6, sid, timeout=60)
        check("L2-06b", "非图片 data URL 202 透传（契约观察，不拒绝）", "/v1/runs",
              st6 == 202 and bool(rid6),
              "status=%s（不入 staging，原样交模型）" % st6)
        if rid6:
            wait_terminal(rid6, 180, "L2-06b")

        # L2-02 全链路（文字+真实照片）
        inp2 = build_user_message("请一句话简要描述这张图片里的内容。", [prep["dataUrl"]])
        st2, rid2, _ = start_run("L2-02a", inp2, sid)
        check("L2-02a", "创建多模态 run（202+run_id）", "/v1/runs",
              st2 == 202 and bool(rid2))
        status2, fin2 = wait_terminal(rid2, 300, "L2-02b")
        reply2 = extract_reply(fin2)
        check("L2-02b", "run 终态 completed 且回复非空", "/v1/runs/%s" % rid2,
              status2 == "completed" and bool(reply2),
              "status=%s reply_len=%d" % (status2, len(reply2)))
        if reply2:
            # 人工对照原图（L3 报告依据）
            print("       L2-02 回复: %s" % reply2[:400])

        # L2-03 image-only（无 text part）
        inp3 = build_user_message("", [prep["dataUrl"]])
        st3, rid3, _ = start_run("L2-03a", inp3, sid)
        check("L2-03a", "创建 image-only run（202）", "/v1/runs",
              st3 == 202 and bool(rid3))
        status3, fin3 = wait_terminal(rid3, 300, "L2-03b")
        reply3 = extract_reply(fin3)
        check("L2-03b", "image-only run 终态 completed 且回复非空",
              "/v1/runs/%s" % rid3,
              status3 == "completed" and bool(reply3),
              "status=%s reply_len=%d" % (status3, len(reply3)))

        # L2-05 文本回归（M1 纯字符串 input，守护 createRun 放宽回归）
        st5, rid5, _ = start_run("L2-05a", "只回复 M0-OK。不要调用任何工具。", sid)
        check("L2-05a", "创建文本 run（M1 形态, 202）", "/v1/runs",
              st5 == 202 and bool(rid5))
        status5, fin5 = wait_terminal(rid5, 150, "L2-05b")
        out5 = json.dumps(fin5 or {}, ensure_ascii=False)
        check("L2-05b", "文本 run 终态 completed（input 放宽无回归）",
              "/v1/runs/%s" % rid5,
              status5 == "completed" and "M0-OK" in out5, "status=%s" % status5)
    finally:
        delete_session(sid)

    fails = [r for r in RESULTS if r[3] == "FAIL"]
    print("SUMMARY: total=%d pass=%d fail=%d evidence=%s"
          % (len(RESULTS), len(RESULTS) - len(fails), len(fails), EVID.name))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
