"""Minimal MCP clients for tests: stdio subprocess and localhost HTTP."""

import json
import os
import subprocess
import sys
import threading
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "..", "mod", "Contents", "mods", "ZomboidMCP", "mcp", "zomboid_mcp.py")


class StdioClient(object):
    def __init__(self, extra_args, env=None):
        self.proc = subprocess.Popen([sys.executable, SERVER] + list(extra_args), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.next_id = 1
        self.lock = threading.Lock()
        self.pending = {}
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        for line in self.proc.stdout:
            try:
                msg = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            with self.lock:
                ev = self.pending.get(msg.get("id"))
            if ev is not None:
                ev[1] = msg
                ev[0].set()

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def send_raw(self, text):
        self.proc.stdin.write((text + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=30):
        with self.lock:
            id_ = self.next_id
            self.next_id += 1
            ev = [threading.Event(), None]
            self.pending[id_] = ev
        msg = {"jsonrpc": "2.0", "id": id_, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        if not ev[0].wait(timeout):
            raise TimeoutError("no response to %s" % method)
        return ev[1]

    def call(self, name, arguments=None, timeout=30):
        resp = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout)
        assert "result" in resp, resp
        return resp["result"]

    def initialize(self):
        r = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "test", "version": "0"}})
        self.notify("notifications/initialized")
        return r

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        err = self.proc.stderr.read().decode("utf-8", "replace")
        self.proc.stderr.close()
        self.reader.join(timeout=2)
        self.proc.stdout.close()
        return err


class HttpClient(object):
    def __init__(self, base_url):
        self.url = base_url
        self.session = None
        self.next_id = 1

    def post(self, msg, headers=None):
        data = json.dumps(msg).encode("utf-8")
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session:
            h["Mcp-Session-Id"] = self.session
        h.update(headers or {})
        req = urllib.request.Request(self.url, data=data, headers=h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read()
                return resp.status, dict(resp.headers), (json.loads(body) if body else None)
        except urllib.error.HTTPError as e:
            body = e.read()
            return e.code, dict(e.headers), (json.loads(body) if body else None)

    def request(self, method, params=None):
        id_ = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": id_, "method": method}
        if params is not None:
            msg["params"] = params
        status, headers, body = self.post(msg)
        if method == "initialize":
            self.session = headers.get("Mcp-Session-Id")
        return status, headers, body

    def call(self, name, arguments=None):
        status, _, body = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        assert status == 200 and "result" in body, (status, body)
        return body["result"]
