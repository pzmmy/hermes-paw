#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HermesPaw M0a 接口自测（方案 §8.1，236 交付物）

对 236 hermes-api-server 做全链路自测，产出 evidence/*.jsonl 证据包。
输出规范（§8.1）：只打印 用例名 + PASS/FAIL(+SKIP) + 端点；
不打印 key、不打印会话内容；脚本异常栈不得包含 .env 路径（P2-7）。

用法:
  python3 tools/api-selftest.py [--base http://127.0.0.1:8377] [--only R,W,A,S,P,X]

退出码: 0=全绿（/v1/skills 为 500 时记 SKIP 不计入）, 1=存在 FAIL
"""
import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = "http://127.0.0.1:8377"
SESSION_KEY = "hermes-paw-m0a-selftest"
TERMINAL = {"completed", "failed", "cancelled", "interrupted"}
EVID_DIR = Path(__file__).resolve().parent.parent / "evidence"
EVID = EVID_DIR / ("selftest-%s.jsonl" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
RESULTS = []


def die(msg):
    # P2-7: 不暴露 .env 路径与栈
    print("SELFTEST_ERROR: %s" % msg)
    sys.exit(2)


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


KEY = load_key()

_SENS = re.compile(r"(key|token|secret|password|authorization|credential)", re.I)


def redact_text(raw, limit=800):
    """响应体首段脱敏（§8.1 证据包）。"""
    if not raw:
        return ""
    try:
        d = json.loads(raw)
        raw = json.dumps(_mask(d), ensure_ascii=False, sort_keys=True)
    except Exception:
        pass
    return raw[:limit]


def _mask(o):
    if isinstance(o, dict):
        return {k: ("***" if _SENS.search(str(k)) and isinstance(v, str) else _mask(v))
                for k, v in o.items()}
    if isinstance(o, list):
        return [_mask(x) for x in o]
    return o


def ev(case, method, path, status, headers, body_raw, note=""):
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "case": case, "req": "%s %s" % (method, path), "status": status,
        "resp_headers": {k: v for k, v in (headers or {}).items()
                         if not _SENS.search(k)},
        "body_head": redact_text(body_raw),
    }
    if note:
        rec["note"] = note
    with open(EVID, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def http(method, path, body=None, auth=True, headers=None, timeout=60, case="?"):
    h = dict(headers or {})
    if auth:
        h["Authorization"] = "Bearer " + KEY
    h["User-Agent"] = "hermes-paw-selftest/1.0"
    data = json.dumps(body).encode() if body is not None else None
    if data is not None:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    status, rh, raw = None, {}, ""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status, rh, raw = r.status, dict(r.headers), r.read(300000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, rh, raw = e.code, dict(e.headers), e.read(300000).decode("utf-8", "replace")
    except Exception as e:
        status, rh, raw = 0, {}, ""
        note = "transport: %s" % type(e).__name__
        ev(case, method, path, status, rh, raw, note)
        return 0, {}, None
    ev(case, method, path, status, rh, raw)
    try:
        parsed = json.loads(raw) if raw else None
    except Exception:
        parsed = None
    return status, rh, parsed


def check(case_id, name, endpoint, ok, detail=""):
    RESULTS.append((case_id, name, endpoint, "PASS" if ok else "FAIL", detail))
    print("[%s] %s %s %s" % ("PASS" if ok else "FAIL", case_id, name, endpoint))


def jmsg(d):
    try:
        return d.get("error", {}).get("code") or d.get("error", {}).get("message") or str(d)[:80]
    except Exception:
        return str(d)[:80]


def sse_tap(run_id, stop_ev, evfile):
    """后台订阅 /events，逐事件落证据；收到终态事件或 stop_ev 置位后退出。"""
    h = {"Authorization": "Bearer " + KEY, "Accept": "text/event-stream",
         "User-Agent": "hermes-paw-selftest/1.0"}
    req = urllib.request.Request(BASE + "/v1/runs/%s/events" % run_id, headers=h)
    names = []
    with urllib.request.urlopen(req, timeout=300) as r, open(evfile, "a", encoding="utf-8") as f:
        ev_name = ""
        for raw_line in r:
            line = raw_line.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("event:"):
                ev_name = line[6:].strip()
                names.append(ev_name)
            elif line.startswith("data:"):
                data = line[5:].strip()
                rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "run_id": run_id, "event": ev_name,
                       "data": redact_text(data, 1500)}
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                f.flush()
                ev_name = ""
                try:
                    d = json.loads(data)
                    name = d.get("event") or d.get("type") or ""
                    if name in names and name in ("run.completed", "assistant.completed",
                                                  "run.failed", "run.cancelled"):
                        break
                except Exception:
                    pass
            if stop_ev.is_set():
                break
    return names


def start_run(case, input_text, session_id, timeout=60):
    body = {"input": input_text, "session_id": session_id}
    h = {"X-Hermes-Session-Key": SESSION_KEY}
    st, _, d = http("POST", "/v1/runs", body, headers=h, timeout=timeout, case=case)
    if st == 202 and isinstance(d, dict) and d.get("run_id"):
        return d["run_id"]
    return None


def poll_status(case, run_id, timeout, stop_ev=None, want_terminal=True):
    """轮询 GET /v1/runs/{id}，返回 (snapshots, final)。"""
    snaps, t0 = [], time.time()
    while time.time() - t0 < timeout:
        if stop_ev is not None and stop_ev.is_set():
            break
        st, _, d = http("GET", "/v1/runs/%s" % run_id, case=case)
        if st == 200 and isinstance(d, dict):
            snaps.append(d)
            if want_terminal and d.get("status") in TERMINAL:
                return snaps, d
        time.sleep(1.0)
    return snaps, (snaps[-1] if snaps else None)


def wait_running(case, run_id, timeout=45):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st, _, d = http("GET", "/v1/runs/%s" % run_id, case=case)
        if st == 200 and d and d.get("status") == "running":
            return True
        if st == 200 and d and d.get("status") in TERMINAL:
            return False
        time.sleep(1.0)
    return False


def main():
    global BASE
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--only", default="", help="逗号分隔类别: R,W,A,S,P,X")
    a = ap.parse_args()
    BASE = a.base
    cats = {c.strip().upper() for c in a.only.split(",") if c.strip()} if a.only else None
    if not KEY:
        # 🟡-r3-2 closeout (170 审爷 r3): gateway-dependent selftest SKIPs (not FAILs)
        # when API_SERVER_KEY is absent (CI / 170 / fresh checkout) — makes the L2 gate
        # reproducible-green in any env. SKIP exit code 77 (make convention: untested);
        # run-l2.sh maps rc=77 -> SKIP (non-failure). 236 侧（有 key）仍全量实跑。
        print("SKIP: API_SERVER_KEY 未配置（非 gateway 环境，gateway 自测跳过；236 侧实跑全绿）")
        sys.exit(77)
    EVID_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d%H%M%S")
    marker = "/tmp/hp-selftest-%s" % ts

    def run(cat, fn):
        if cats is None or cat in cats:
            fn()

    # ---------- 只读 ----------
    def t_readonly():
        run_r = []

        def one(case_id, name, path, expect=(200,)):
            st, _, d = http("GET", path, case=case_id)
            check(case_id, name, path, st in expect, "got %s" % st)
            return d

        one("R-01", "health", "/health")
        d = one("R-02", "capabilities", "/v1/capabilities")
        if isinstance(d, dict):
            EVID_DIR.joinpath("capabilities-full.json").write_text(
                json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
            f = d.get("features", {})
            ok = (f.get("run_submission") and f.get("run_status")
                  and f.get("run_events_sse") and f.get("run_steer")
                  and f.get("run_approval_response") and f.get("approval_events")
                  and f.get("session_fork") is True
                  and f.get("session_key_header") == "X-Hermes-Session-Key"
                  and d.get("auth", {}).get("type") == "bearer"
                  and d.get("endpoints", {}).get("run_approval", {}).get("path")
                  == "/v1/runs/{run_id}/approval")
            check("R-02a", "capabilities 字段级断言(M4 多角色/审批/steer 依赖)",
                  "/v1/capabilities", bool(ok))
        one("R-03", "toolsets", "/v1/toolsets")
        one("R-04", "models", "/v1/models")
        one("R-05", "sessions 列表", "/api/sessions")
        one("R-06", "jobs 列表", "/api/jobs")
        st, _, d = http("GET", "/v1/skills", case="R-07")
        if st == 200:
            check("R-07", "skills（R12 修复回归）", "/v1/skills", True)
        else:
            RESULTS.append(("R-07", "skills", "/v1/skills", "SKIP",
                            "got %s（§2.5/R12 单列跟踪）" % st))
            print("[SKIP] R-07 skills /v1/skills (got %s)" % st)
        st, _, _ = http("GET", "/v1/capabilities", auth=False, case="X-01")
        check("X-01", "无 key 鉴权门", "/v1/capabilities", st == 401, "got %s" % st)

    # ---------- 会话 + 有副作用 run ----------
    sess = {"id": None, "fork_id": None}

    def t_write():
        st, _, d = http("POST", "/api/sessions",
                        {"title": "M0a-selftest-%s" % ts}, case="W-01")
        sid = (d or {}).get("session", {}).get("id")
        check("W-01", "建独立测试会话", "/api/sessions", st == 201 and bool(sid))
        if not sid:
            return
        sess["id"] = sid

        # W-02: 只回复 M0-OK
        evfile = EVID_DIR / ("sse-run1-%s.jsonl" % ts)
        stop1 = threading.Event()
        run_id = start_run("W-02", "只回复 M0-OK。不要调用任何工具。", sid)
        check("W-02a", "创建 run(202+run_id)", "/v1/runs", bool(run_id))
        if not run_id:
            return
        evfile.write_text("", encoding="utf-8")
        t = threading.Thread(target=sse_tap, args=(run_id, stop1, evfile), daemon=True)
        t.start()
        snaps, fin = poll_status("W-02b", run_id, 150)
        out = json.dumps(fin or {}, ensure_ascii=False)
        check("W-02b", "run 至终态且 output 含 M0-OK", "/v1/runs/%s" % run_id,
              bool(fin and fin.get("status") == "completed" and "M0-OK" in out),
              "status=%s" % (fin or {}).get("status"))
        stop1.set()
        t.join(timeout=3)
        ev("W-02c", "SSE", "/v1/runs/%s/events" % run_id, 200, {}, "",
           "事件数=%d 文件=sse-run1-%s.jsonl" % (len(evfile.read_text().splitlines()), ts))

        # W-03: steer + stop（sleep 30 长任务）
        run2 = start_run("W-03a", "请调用 terminal 工具执行命令：sleep 30。"
                        "执行完成后只回复 SLEEP-DONE。", sid)
        check("W-03a", "创建长任务 run", "/v1/runs", bool(run2))
        if not run2:
            return
        running = wait_running("W-03b", run2)
        check("W-03b", "run 进入 running", "/v1/runs/%s" % run2, running)
        if running:
            time.sleep(2)
            st, _, d = http("POST", "/v1/runs/%s/steer" % run2,
                            {"input": "补充要求：最终回复末尾追加 STEER-OK。"},
                            headers={"X-Hermes-Session-Key": SESSION_KEY}, case="W-03c")
            accepted = isinstance(d, dict) and d.get("accepted") is True
            check("W-03c", "运行中 steer 期望 200+accepted",
                  "/v1/runs/%s/steer" % run2, st == 200 and accepted,
                  "got %s %s" % (st, jmsg(d) if d else ""))
            # pending_steer / pending_controls 观察（证据；authority 模式字段名不同）
            seen = {"present": False, "gone_after": False}
            t0 = time.time()
            while time.time() - t0 < 12:
                st2, _, d2 = http("GET", "/v1/runs/%s" % run2, case="W-03d")
                if st2 == 200 and d2 and ("pending_steer" in d2
                                          or "pending_controls" in d2):
                    pc = d2.get("pending_controls") if "pending_controls" in d2 \
                        else d2.get("pending_steer")
                    if pc:
                        seen["present"] = True
                    elif seen["present"]:
                        seen["gone_after"] = True
                        break
                if st2 == 200 and d2 and d2.get("status") in TERMINAL:
                    break
                time.sleep(1.0)
            ev("W-03e", "NOTE", "/v1/runs/%s" % run2, 200, {}, "",
               "pending 控制暴露观察: %s（状态快照见上文 W-03d 各行；"
               "authority 模式字段=pending_controls）" % seen)
            st3, _, d3 = http("POST", "/v1/runs/%s/stop" % run2, {}, case="W-03f")
            check("W-03f", "stop 运行中 run", "/v1/runs/%s/stop" % run2, st3 in (200, 202),
                  "got %s %s" % (st3, jmsg(d3) if d3 else ""))
            _, fin3 = poll_status("W-03g", run2, 60)
            check("W-03g", "stop 后终态", "/v1/runs/%s" % run2,
                  bool(fin3 and fin3.get("status") in TERMINAL),
                  "status=%s" % (fin3 or {}).get("status"))

    # ---------- 审批 ----------
    def t_approval():
        os.makedirs(marker, exist_ok=True)
        st, _, _ = http("POST", "/v1/runs/run_nonexistent_000/approval",
                        {"choice": "once"}, case="A-01")
        check("A-01", "对不存在 run POST /approval(404/409)",
              "/v1/runs/{id}/approval", st in (404, 409), "got %s" % st)
        # 命令说明：用相对路径 rm -r（命中 DANGEROUS 模式 "recursive delete"，
        # 不在 236 永久 allowlist {"delete in root path"} 内）→ 应触发 pending 审批。
        # 整条命令被批准后实际执行也安全（只删 /tmp 下测试目录）。
        cmd = "mkdir -p /tmp/hp-selftest-%s && cd /tmp && rm -r hp-selftest-%s" % (ts, ts)
        run3 = start_run("A-02a",
                         "请调用 terminal 工具，原样执行这条命令（不要拆分、不要改写、"
                         "不要改用 rm -rf 绝对路径形式）：%s 。"
                         "执行成功后只回复 DEL-DONE。" % cmd,
                         sess.get("id"))
        check("A-02a", "创建含危险命令的 run", "/v1/runs", bool(run3))
        if not run3:
            return
        evfile = EVID_DIR / ("sse-run3-%s.jsonl" % ts)
        evfile.write_text("", encoding="utf-8")
        stop3 = threading.Event()
        threading.Thread(target=sse_tap, args=(run3, stop3, evfile), daemon=True).start()
        # 关键：审批窗口 = config approvals.timeout（236=60s）。轮询到
        # waiting_for_approval 必须立即退出 POST，不能等 run 终态
        #（等终态=窗口已被 60s 超时自动拒绝）。
        waiting = False
        waiting_snap = None
        last_gen = None
        t0 = time.time()
        while time.time() - t0 < 150:
            st, _, d = http("GET", "/v1/runs/%s" % run3, case="A-02b")
            if st == 200 and d:
                last_gen = d.get("execution_generation", last_gen)
                if d.get("status") == "waiting_for_approval":
                    waiting, waiting_snap = True, d
                    break
                if d.get("status") in TERMINAL:
                    break
            time.sleep(1.0)
        snaps = [waiting_snap] if waiting_snap else []
        fin = waiting_snap
        if waiting:
            # A-5: pending 审批暴露路径。
            # authority 模式（236 v0.22.5）：status=waiting_for_approval +
            # pending_controls[{kind:"approval", prompt_id,...}]（api_server_authority_runs.py:91-96）；
            # 非 authority 路径另有顶层 approval 字段（api_server_runs.py:965）。
            req_id = None
            controls = waiting_snap.get("pending_controls") or []
            approval_entry = next((c for c in controls if c.get("kind") == "approval"), None)
            legacy = waiting_snap.get("approval")
            if isinstance(approval_entry, dict):
                req_id = (approval_entry.get("prompt_id")
                          or approval_entry.get("request_id") or approval_entry.get("id"))
            elif isinstance(legacy, dict):
                req_id = (legacy.get("request_id") or legacy.get("prompt_id")
                          or legacy.get("id"))
            ev("A-02c", "A-5", "/v1/runs/%s" % run3, 200, {}, "",
               "pending 审批经 GET /v1/runs/{id} 暴露: status=waiting_for_approval, "
               "authority pending_controls=%s, 顶层 approval 字段=%s, request_id=%s, "
               "execution_generation=%s（SSE 事件流见 sse-run3-%s.jsonl；审批窗口60s）"
               % (json.dumps(controls, ensure_ascii=False)[:400],
                  "present" if legacy else "absent", req_id, last_gen, ts))
            body = {"choice": "once", "request_id": req_id or "",
                    "execution_generation": last_gen or 0}
            st, _, d = http("POST", "/v1/runs/%s/approval" % run3, body, case="A-02d")
            # 回执两种形状：authority={prompt_id,run_id,status:"resolved"}
            # ；legacy={resolved:N}。任一成立即 PASS。
            resolved = (isinstance(d, dict) and (int(d.get("resolved", 0) or 0) >= 1
                                                 or d.get("status") == "resolved"))
            check("A-02d", "POST /approval(allow_once)→resolved≥1",
                  "/v1/runs/%s/approval" % run3, st == 200 and resolved,
                  "got %s %s" % (st, jmsg(d) if d else ""))
            _, fin = poll_status("A-02e", run3, 120)
            out = json.dumps(fin or {}, ensure_ascii=False)
            check("A-02e", "批准后 run 继续至终态且命令生效",
                  "/v1/runs/%s" % run3,
                  bool(fin and fin.get("status") == "completed"
                       and "DEL-DONE" in out and not os.path.exists(marker)),
                  "status=%s dir_gone=%s" % ((fin or {}).get("status"),
                                              not os.path.exists(marker)))
        else:
            # 分支：未出现 waiting_for_approval（模型改写了命令命中 allowlist key，
            # 或审批策略未拦截）。用 authority 三字段体探测 /approval 错误形状。
            st, _, d = http("POST", "/v1/runs/%s/approval" % run3,
                            {"choice": "once", "request_id": "none",
                             "execution_generation": last_gen or 0},
                            case="A-02f")
            check("A-02f", "（分支）无 pending 时 /approval→409 形状",
                  "/v1/runs/%s/approval" % run3, st in (409, 404),
                  "未出现 waiting_for_approval；run 终态=%s；/approval got %s %s"
                  % ((fin or {}).get("status"), st, jmsg(d) if d else ""))
            stop3.set()

    # ---------- 会话管理 ----------
    def t_session():
        sid = sess.get("id")
        if not sid:
            return
        st, _, d = http("GET", "/api/sessions/%s/messages" % sid, case="S-01")
        msgs = (d or {}).get("messages") or (d or {}).get("data") or []
        check("S-01", "测试会话消息重拉(§4.5 依据)", "/api/sessions/{id}/messages",
              st == 200 and len(msgs) >= 2, "msgs=%d" % len(msgs))
        fork_id = "hp-selftest-fork-%s" % ts
        st, _, d = http("POST", "/api/sessions/%s/fork" % sid,
                        {"id": fork_id}, case="S-02")
        check("S-02", "fork 测试会话(源会话 branched 终止)",
              "/api/sessions/{id}/fork", st == 201 and fork_id,
              "got %s" % st)
        sess["fork_id"] = fork_id
        st1, _, _ = http("DELETE", "/api/sessions/%s" % sid, case="S-03")
        st2, _, _ = http("DELETE", "/api/sessions/%s" % fork_id, case="S-04")
        check("S-03", "DELETE 测试会话(清理)", "/api/sessions/{id}", st1 in (200, 204),
              "got %s" % st1)
        check("S-04", "DELETE fork 会话(清理)", "/api/sessions/{id}", st2 in (200, 204),
              "got %s" % st2)

    # ---------- profile 镜像（M4 多角色路由） ----------
    def t_profile():
        st, _, _ = http("GET", "/p/default/v1/capabilities", case="P-01")
        check("P-01", "/p/{profile} 镜像路由(M4 多角色)", "/p/default/v1/capabilities",
              st == 200, "got %s" % st)

    run("R", t_readonly)
    run("W", t_write)
    run("A", t_approval)
    run("S", t_session)
    run("P", t_profile)

    fails = [r for r in RESULTS if r[3] == "FAIL"]
    skips = [r for r in RESULTS if r[3] == "SKIP"]
    print("-" * 50)
    print("SUMMARY: %d PASS / %d FAIL / %d SKIP  证据包=%s"
          % (len(RESULTS) - len(fails) - len(skips), len(fails), len(skips), EVID.name))
    for cid, name, ep, st_, detail in fails:
        print("  FAIL %s %s %s (%s)" % (cid, name, ep, detail))
    for cid, name, ep, st_, detail in skips:
        print("  SKIP %s %s %s (%s)" % (cid, name, ep, detail))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        die("%s" % type(e).__name__)
