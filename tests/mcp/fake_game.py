"""A fake Project Zomboid server for tests: plays the game side of the Bridge.lua file protocol.

It watches a Lua dir like Bridge.lua 0.2.0 does (docs/PROTOCOL.md): executes
zmcp_req_<n>.json in order, writes zmcp_res_<n>.json terminated by a newline,
writes zmcp_status.json every `status_interval` seconds and after each request,
probes for gaps, and appends events to zmcp_events.jsonl. With ``legacy=True``
it behaves like Bridge 0.1.0 (no trailing newline, request file blanked instead).
"""

import json
import os
import threading
import time


class FakeGame(threading.Thread):
    def __init__(self, lua_dir, next_req=1, status_interval=0.2, players=None, tick=0.02, legacy=False):
        threading.Thread.__init__(self, daemon=True)
        self.lua_dir = lua_dir
        self.legacy = legacy
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
        self.tools = {
            "ping": lambda a: {"pong": True, "version": "fake", "players": ", ".join(p["user"] for p in self.players)},
            "lua_eval": self._lua_eval,
            "tools_list": lambda a: [{"name": n, "desc": "fake tool %s" % n} for n in sorted(self.tools)],
            "run_file": self._run_file,
            "echo": lambda a: a,
            "slow": self._slow,
            "fail": self._fail,
            "blob_check": self._blob_check,
            "keep": lambda a: {"keep_files": True, "got": sorted(a)},
            "custom_thing": lambda a: {"custom": True, "args": a},
        }
        self.last_status = 0.0
        self.version = "0.1.0-fake" if legacy else "0.2.0-fake"

    # --- tools ----------------------------------------------------------------
    def _lua_eval(self, a):
        code = a.get("code", "")
        if code.strip() == "return 1+1":
            return 2
        if code.strip().startswith("error("):
            raise RuntimeError(code.strip()[6:].strip("()\"'"))
        if code.strip() == "return getOnlinePlayers():size()":
            return len(self.players)
        return {"evaluated": code}

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
        with open(self._p("zmcp_events.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": int(time.time()), "kind": kind, "data": data}) + "\n")

    def write_status(self):
        st = {"version": self.version, "t": time.time(), "nextReq": self.next_req, "server": True,
              "players": self.players, "time": {"hour": 12.5, "day": 3, "month": 7, "year": 1993}}
        if self.legacy:
            st["tools"] = len(self.tools)
            self._write("zmcp_status.json", json.dumps(st))
        else:
            st.update({"bootId": self.boot_id, "paused": not self.players, "tps": 0 if not self.players else 10,
                       "uptime": 1, "tools": sorted(self.tools), "modules": [], "stats": {"requests": len(self.calls), "errors": 0}})
            self._write("zmcp_status.json", json.dumps(st) + "\n")
        self.last_status = time.time()

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
        if self.legacy:
            self._write("zmcp_res_%d.json" % n, json.dumps(res))
            self._write("zmcp_req_%d.json" % n, "")
        else:
            res["n"] = n
            res["t"] = time.time()
            self._write("zmcp_res_%d.json" % n, json.dumps(res) + "\n")
        return True

    def tick(self):
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
        if processed or time.time() - self.last_status >= self.status_interval:
            self.write_status()

    def run(self):
        self.event("bridge_loaded", {"version": self.version, "nextReq": self.next_req})
        while self.running:
            if not self.paused:
                self.tick()
            time.sleep(self.tick_s)

    def stop(self):
        self.running = False
        self.join(timeout=2)
