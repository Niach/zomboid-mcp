#!/usr/bin/env python3
"""Live smoke test of the file bridge against a running server (docs/PROTOCOL.md).

Needs the bridge loaded (tools/pz load) and the env from ~/.config/zomboid-mcp/local.env
(ZMCP_SSH, ZMCP_LUA_DIR, ZMCP_CONTAINER / ZMCP_POLL_FILE for the paused path):
    . ~/.config/zomboid-mcp/local.env && ZMCP_POLL_FILE=VappsGuardian.lua tests/smoke_live.py
Only non-destructive tools are used (ping, lua_eval on bridge state, tools_list, module_install of a
no-op module that is removed again).
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
from zmcp_client import BridgeError, Client, REQ  # noqa: E402

results = []


def check(name, fn):
    t0 = time.time()
    try:
        info = fn()
        results.append((name, True, time.time() - t0, info))
        print(f"ok   {name} ({(time.time() - t0) * 1000:.0f} ms) {info if info is not None else ''}")
    except Exception as e:  # noqa: BLE001
        results.append((name, False, time.time() - t0, str(e)))
        print(f"FAIL {name}: {e}")


def main():
    c = Client.from_env()
    status = c.status()
    if not status:
        print("no zmcp_status.json: load the bridge first (tools/pz load)")
        return 2
    print(f"bridge {status.get('version')} bootId={status.get('bootId')} paused={status.get('paused')} "
          f"players={len(status.get('players', []))} nextReq={status.get('nextReq')}")

    def ping():
        r = c.call("ping")
        assert r["pong"] is True and r["bootId"] == status["bootId"], r
        return f"paused={r['paused']}"
    check("ping", ping)

    def lua_eval():
        assert c.eval("return 1 + 1") == 2
        assert c.eval("return 'a', 2, true") == ["a", 2, True]
        assert c.eval("return {x = 1, list = {1, 2, 3}}") == {"x": 1, "list": [1, 2, 3]}
        assert c.eval("return nil") is None
        return "scalars, multiple returns, tables"
    check("lua_eval", lua_eval)

    def lua_error():
        try:
            c.eval("error('boom')")
        except BridgeError as e:
            assert "boom" in str(e), e
            return "error propagated"
        raise AssertionError("no error raised")
    check("lua_eval error", lua_error)

    def compile_error():
        try:
            c.eval("this is not lua")
        except BridgeError as e:
            assert "compile" in str(e), e
            return "compile error reported"
        raise AssertionError("no error raised")
    check("lua_eval compile error", compile_error)

    def tools_list():
        tools = {t["name"] for t in c.call("tools_list")}
        for name in ("ping", "lua_eval", "tools_list", "run_file", "module_install", "module_list", "module_remove", "status"):
            assert name in tools, name
        return f"{len(tools)} tools"
    check("tools_list", tools_list)

    def unknown_tool():
        try:
            c.call("no_such_tool")
        except BridgeError as e:
            assert "unknown tool" in str(e), e
            return "rejected"
        raise AssertionError("no error raised")
    check("unknown tool", unknown_tool)

    def ordering():
        # requests execute strictly in order; a request that consumes the previous one's side effect proves it
        c.eval("ZMCP._smoke = 0")
        for i in range(5):
            c.eval(f"ZMCP._smoke = ZMCP._smoke * 10 + {i + 1}")
        v = c.eval("local v = ZMCP._smoke ZMCP._smoke = nil return v")
        assert v == 12345, v
        return "5 requests in order"
    check("ordering", ordering)

    def latency():
        times = []
        for _ in range(10):
            t0 = time.time(); c.call("ping"); times.append(time.time() - t0)
        avg = sum(times) / len(times)
        assert max(times) < 1.0, f"max {max(times):.2f} s"
        return f"ping x10 min {min(times)*1000:.0f} avg {avg*1000:.0f} max {max(times)*1000:.0f} ms"
    check("latency < 1 s", latency)

    def gap():
        # skip a number: the server must find the request behind the gap
        c.n += 3
        r = c.call("ping")
        assert r["pong"], r
        st = c.call("status")
        assert st["nextReq"] == c.n, (st["nextReq"], c.n)
        return "server jumped over the gap"
    check("gap handling", gap)

    def restart_lower():
        # simulate a restart that lost the counter: the server's nextReq drops below the client's
        c.eval("ZMCP.nextReq = ZMCP.nextReq - 30; ModData.getOrCreate('ZomboidMCP').nextReq = ZMCP.nextReq")
        # ... but the client keeps writing at its own number, 31 ahead: unreachable, times out, resyncs, retries
        old_timeout = c.timeout
        c.timeout = 2
        try:
            r = c.call("ping")
        finally:
            c.timeout = old_timeout
        assert r["pong"], r
        st = c.call("status")
        assert st["nextReq"] == c.n
        return "resynced after the server fell behind"
    check("resync after lower nextReq", restart_lower)

    def stale():
        # a request with an old timestamp is refused (never executed late)
        n = c.n
        c.n += 1
        body = c.t.request(n, json.dumps({"n": n, "t": time.time() - 3600, "tool": "lua_eval", "args": {"code": "ZMCP._stale = true"}}), c.timeout)
        res = json.loads(body)
        assert res["ok"] is False and "stale" in res["error"], res
        assert c.eval("return ZMCP._stale") is None
        return "refused"
    check("stale request refused", stale)

    def bad_json():
        n = c.n
        c.n += 1
        body = c.t.request(n, "{not json", c.timeout)
        res = json.loads(body)
        assert res["ok"] is False and "bad request json" in res["error"], res
        return "answered with an error"
    check("malformed request", bad_json)

    def modules():
        r = c.call("module_install", {"name": "smoke_test", "code": "ZMCP._smokeModule = (ZMCP._smokeModule or 0) + 1 return 'hi'"})
        assert r["result"] == "hi", r
        assert any(m["name"] == "smoke_test" for m in c.call("module_list"))
        assert "smoke_test" in c.call("status")["modules"]
        r = c.call("module_remove", {"name": "smoke_test"})
        assert r["removed"] == "smoke_test"
        assert not any(m["name"] == "smoke_test" for m in c.call("module_list"))
        c.eval("ZMCP._smokeModule = nil")
        return "install, list, status, remove"
    check("module_install/list/remove", modules)

    def run_file():
        c.t.put("zmcp_run.lua", "return {from = 'file', n = 3}")     # the MCP may write .lua; the server may not
        assert c.call("run_file", {"file": "zmcp_run.lua"}) == {"from": "file", "n": 3}
        return "ran"
    check("run_file", run_file)

    def events():
        ev = c.events(50)
        assert any(e.get("kind") == "bridge_loaded" for e in ev), ev[-3:]
        assert any(e.get("kind") == "gap" for e in ev), "no gap event"
        return f"{len(ev)} events read"
    check("events log", events)

    def leftovers():
        _, names = c.t.resync_info()
        left = [x for x in names if x.startswith(REQ) or x.startswith("zmcp_res_")]
        assert not left, left
        return "no request/response files left behind"
    check("cleanup", leftovers)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
