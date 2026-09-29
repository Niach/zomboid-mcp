"""A fake Project Zomboid server for tests: plays the game side of the Bridge.lua file protocol.

It watches a Lua dir like Bridge.lua does (docs/PROTOCOL.md): executes
zmcp_req_<n>.json in order, writes zmcp_res_<n>.json terminated by a newline,
writes zmcp_status.json every `status_interval` seconds and after each request,
probes for gaps, and appends events to zmcp_events.log. While ``paused`` it
does nothing until ``poll()`` is called (like a PauseEmpty server woken by
``reloadlua``); a poll command that touches ``<lua_dir>/POLLED`` triggers that.
"""

import json
import os
import threading
import time


class FakeGame(threading.Thread):
    def __init__(self, lua_dir, next_req=1, status_interval=0.2, players=None, tick=0.02):
        threading.Thread.__init__(self, daemon=True)
        self.lua_dir = lua_dir
        self.polls = 0                # poll() calls (paused server woken through the console)
        self.boot_id = "%d-%d" % (int(time.time()), os.getpid())
        self.requests_seen = []       # raw request dicts, to check n/t fields
        self.next_req = next_req
        self.status_interval = status_interval
        self.players = players if players is not None else [
            {"user": "niach", "name": "Cool Jesus", "x": 6400, "y": 5498, "z": 0, "dead": False, "health": 100}]
        self.tick_s = tick
        self.paused = False           # like PauseEmpty: no ticks, no heartbeat
        self.running = True
        self.calls = []               # (tool, args) executed
        self.client_results = {}      # script id -> result status returned by client_results
        self.tools = {
            "ping": lambda a: {"pong": True, "version": "fake", "players": ", ".join(p["user"] for p in self.players)},
            "run_lua_server": self._run_lua_server,
            "run_lua_client": self._run_lua_client,
            "client_results": self._client_results,
            "tools_list": lambda a: [{"name": n, "desc": "fake tool %s" % n} for n in sorted(self.tools)],
            "run_file": self._run_file,
            "script_install": self._script_install,
            "script_list": lambda a: {"server": [], "client": []},
            "echo": lambda a: a,
            "slow": self._slow,
            "fail": self._fail,
            "blob_check": self._blob_check,
            "keep": lambda a: {"keep_files": True, "got": sorted(a)},
            "custom_thing": lambda a: {"custom": True, "args": a},
            "texture_upload": self._texture_upload,
        }
        self.last_status = 0.0
        self.version = "0.3.0-fake"

    # --- tools ----------------------------------------------------------------
    def _run_lua_server(self, a):
        code = a.get("code", "")
        if code.strip() == "return 1+1":
            return 2
        if code.strip().startswith("error("):
            raise RuntimeError(code.strip()[6:].strip("()\"'"))
        if code.strip() == "return getOnlinePlayers():size()":
            return len(self.players)
        return {"evaluated": code}

    def _run_lua_client(self, a):
        code = a.get("code") or self._read(a.get("code_file", "")) or ""
        to = [a["player"]] if a.get("player") else [p["user"] for p in self.players]
        sid = a.get("id") or "c%d" % (len(self.client_results) + 1)
        results = {}
        for user in to:
            if user == "slowpoke":
                continue                                       # never answers
            if code.strip().startswith("error("):
                results[user] = {"ok": False, "res": code.strip()[6:].strip("()\"'"), "ms": 1}
            elif code.strip() == "return {a = 1}":
                results[user] = {"ok": True, "res": '{"a":1}', "ms": 1}
            else:
                results[user] = {"ok": True, "res": "ran %d chars" % len(code), "ms": 1}
        self.client_results[sid] = {"id": sid, "to": to, "results": results}
        return {"id": sid, "chunks": max(1, -(-len(code) // 3000)), "to": to}

    def _client_results(self, a):
        r = self.client_results.get(a.get("id"))
        if not r:
            raise RuntimeError("unknown script id %s" % a.get("id"))
        pending = [u for u in r["to"] if u not in r["results"]]
        return dict(r, pending=pending, done=not pending)

    def _script_install(self, a):
        code = a.get("code") or self._read(a.get("code_file", "")) or ""
        name = a.get("name", "")
        if not name or "/" in name or "." in name:
            raise RuntimeError("script name must be a string matching [A-Za-z0-9_-]+")
        side = a.get("side") or "server"
        self._write("zmcp_script_%s.lua.txt" % name, code)
        return {"name": name, "side": side, "file": "zmcp_script_%s.lua.txt" % name, "result": len(code)}

    def _texture_upload(self, a):
        b64 = a.get("png_base64") or self._read(a.get("png_base64_file", "")) or ""
        return {"id": a.get("id"), "gen": 1, "chars": len(b64), "chunks": max(1, -(-len(b64) // 3000))}

    def _run_file(self, a):
        text = self._read(a["file"])
        if text is None:
            raise RuntimeError("file not found in Lua dir: %s" % a["file"])
        return {"ran": a["file"], "bytes": len(text)}

    def _slow(self, a):
        time.sleep(float(a.get("seconds", 1)))
        return {"slept": a.get("seconds", 1)}

    def _fail(self, a):
        raise RuntimeError(a.get("message", "boom"))

    def _blob_check(self, a):
        out = {}
        for k, v in a.items():
            if k.endswith("_file"):
                text = self._read(v)
                out[k] = {"file": v, "bytes": len(text) if text is not None else None}
            else:
                out[k] = len(v) if isinstance(v, str) else v
        return out

    # --- files ----------------------------------------------------------------
    def _p(self, name):
        return os.path.join(self.lua_dir, name)

    def _read(self, name):
        try:
            with open(self._p(name), "r", encoding="utf-8") as f:
                return f.read()
        except OSError:
            return None

    def _write(self, name, text):
        with open(self._p(name), "w", encoding="utf-8") as f:
            f.write(text)

    def event(self, kind, data):
        with open(self._p("zmcp_events.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": int(time.time()), "kind": kind, "data": data}) + "\n")

    def write_status(self):
        st = {"version": self.version, "t": time.time(), "nextReq": self.next_req, "server": True,
              "players": self.players, "time": {"hour": 12.5, "day": 3, "month": 7, "year": 1993},
              "bootId": self.boot_id, "paused": self.paused, "tps": 0 if self.paused else 10,
              "uptime": 1, "tools": sorted(self.tools), "scripts": [], "stats": {"requests": len(self.calls), "errors": 0}}
        self._write("zmcp_status.json", json.dumps(st) + "\n")
        self.last_status = time.time()

    @property
    def poll_cmd(self):
        """Shell command an MCP can use to wake this fake while paused (stands in for `reloadlua` on the console)."""
        return "touch %s" % self._p("POLLED")

    def poll(self):
        """One bridge pass while paused (what `reloadlua ZMCPPoll.lua` does on the real server)."""
        self.polls += 1
        self.tick(force_status=True)

    # --- protocol -------------------------------------------------------------
    def process_one(self, n):
        text = self._read("zmcp_req_%d.json" % n)
        if not text:
            return False
        try:
            req = json.loads(text)
        except ValueError as e:
            res = {"ok": False, "error": "bad json: %s" % e}
        else:
            self.requests_seen.append(req)
            tool = req.get("tool")
            args = req.get("args") or {}
            self.calls.append((tool, args))
            fn = self.tools.get(tool)
            if fn is None:
                res = {"ok": False, "error": "unknown tool '%s'" % tool}
            else:
                try:
                    res = {"ok": True, "result": fn(args)}
                except Exception as e:   # noqa: BLE001
                    res = {"ok": False, "error": str(e)}
                    self.event("tool_error", {"tool": tool, "error": str(e)})
        res["n"] = n
        res["t"] = time.time()
        self._write("zmcp_res_%d.json" % n, json.dumps(res) + "\n")
        return True

    def tick(self, force_status=False):
        budget = 20
        processed = 0
        while budget > 0:
            if self.process_one(self.next_req):
                self.next_req += 1
                budget -= 1
                processed += 1
            else:
                jumped = False
                for k in range(1, 6):
                    t = self._read("zmcp_req_%d.json" % (self.next_req + k))
                    if t:
                        self.next_req += k
                        jumped = True
                        break
                if not jumped:
                    break
        if processed or force_status or time.time() - self.last_status >= self.status_interval:
            self.write_status()

    def run(self):
        self.event("bridge_loaded", {"version": self.version, "nextReq": self.next_req})
        while self.running:
            if not self.paused:
                self.tick()
            elif os.path.exists(self._p("POLLED")):
                os.remove(self._p("POLLED"))
                self.poll()
            time.sleep(self.tick_s)

    def stop(self):
        self.running = False
        self.join(timeout=2)
