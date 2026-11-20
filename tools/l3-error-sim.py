#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mock Hermes gateway for L3 error-state reproduction (S3 acceptance).

Implements the gateway wire surface just well enough for the app's
ApiClient to exercise each S3-a error state:

  mode=5xx      /health -> 200; every other endpoint -> 500 + JSON error
  mode=401      /health -> 200; every other endpoint -> 401 + JSON error
  mode=timeout  accept TCP, read the request, then never respond
                (client hits its own read timeout: ~8s in settings test,
                 up to ~30s on a chat send)

Error body mirrors the real gateway shape:
  {"error": {"code": "...", "message": "..."}}

Usage (on any host the phone can reach, e.g. 236):
  python3 tools/l3-error-sim.py --mode 5xx --port 8378
  python3 tools/l3-error-sim.py --mode timeout --port 8378
  python3 tools/l3-error-sim.py --mode 401 --port 8378
Then in the app: Settings -> edit profile -> address = http://<host>:8378
-> any token -> save, then run the L3 case (see docs/test-target-s3.md).

Zero dependencies (stdlib only). Ctrl-C to stop.
"""
import argparse
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODES = {
    "5xx": (500, "internal_error", "mock internal error (l3-error-sim)"),
    "401": (401, "unauthorized", "invalid or expired API key"),
}
HEALTH_BODY = {"status": "ok", "version": "l3-error-sim"}


class Handler(BaseHTTPRequestHandler):
    mode = "5xx"

    def _reply(self, status: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _drain(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 0:
                self.rfile.read(n)
        except Exception:
            pass

    def _handle(self):
        self._drain()
        if self.path.split("?")[0] == "/health":
            self._reply(200, HEALTH_BODY)
            return
        status, code, msg = MODES[self.mode]
        self._reply(status, {"error": {"code": code, "message": msg}})

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_DELETE(self):
        self._handle()

    def log_message(self, fmt, *args):  # quiet: one line per request
        sys.stderr.write("[l3-error-sim] %s %s\n" % (self.address_string(), fmt % args))


def serve_timeout(host: str, port: int):
    """Accept TCP, read headers, then stall forever (client read-timeout)."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(16)
    print("[l3-error-sim] timeout mode on %s:%d (accept, never respond)" % (host, port))
    while True:
        conn, addr = srv.accept()

        def stall(c):
            try:
                while True:
                    if not c.recv(65536):
                        break
            except OSError:
                pass
            # never send anything back; hold the socket open

        threading.Thread(target=stall, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--mode", choices=sorted(set(MODES) | {"timeout"}), required=True)
    ap.add_argument("--port", type=int, default=8378)
    ap.add_argument("--bind", default="0.0.0.0")
    a = ap.parse_args()
    if a.mode == "timeout":
        serve_timeout(a.bind, a.port)
        return
    Handler.mode = a.mode
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    status, code, msg = MODES[a.mode]
    print("[l3-error-sim] %s mode on %s:%d (health=200, others=%d %s)"
          % (a.mode, a.bind, a.port, status, code))
    srv.serve_forever()


if __name__ == "__main__":
    main()
