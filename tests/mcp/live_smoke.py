#!/usr/bin/env python3
"""Read-only smoke test of zomboid_mcp.py against the real dedicated server.

Opt-in: it needs the deployment details from ~/.config/zomboid-mcp/local.env
(ZMCP_SSH, ZMCP_LUA_DIR, ZMCP_CONTAINER) or the equivalent flags. It only reads:
`status`, `events_poll`, `server_console "players"` and, when the bridge is live,
`run_lua_server "return 1+1"` plus `players_list`. Nothing in the game changes.

    python3 tests/mcp/live_smoke.py                 # uses ~/.config/zomboid-mcp/local.env
    ZMCP_LIVE=1 python3 -m unittest tests.mcp.live_smoke
"""

import json
import os
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mcp_client import StdioClient  # noqa: E402

ENV_FILE = os.path.expanduser("~/.config/zomboid-mcp/local.env")


def text_of(result):
    return "".join(c["text"] for c in result["content"] if c["type"] == "text")


@unittest.skipUnless(os.environ.get("ZMCP_LIVE") or __name__ == "__main__", "set ZMCP_LIVE=1 to run against the live server")
class LiveSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.exists(ENV_FILE):
            raise unittest.SkipTest("no %s" % ENV_FILE)
        cls.client = StdioClient(["--env-file", ENV_FILE, "--timeout", "8"])
        init = cls.client.initialize()
        assert "result" in init, init
        cls.report = {"transport": init["result"]["serverInfo"]["title"]}

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        print("\n" + json.dumps(cls.report, indent=1))

    def test_1_status(self):
        t0 = time.time()
        r = self.client.call("status", timeout=60)
        self.assertFalse(r["isError"], text_of(r))
        st = r["structuredContent"]
        self.report["status"] = {k: st.get(k) for k in ("bridge", "version", "heartbeat_age_s", "hint", "error")}
        self.report["status"]["players"] = [p.get("user") for p in st.get("players") or []]
        self.report["status_s"] = round(time.time() - t0, 2)
        self.assertNotEqual(st["bridge"], "unreachable", st)
        type(self).live = st["bridge"] == "live"

    def test_2_tools_list(self):
        tools = self.client.request("tools/list", timeout=60)["result"]["tools"]
        self.report["tools"] = len(tools)
        self.assertGreaterEqual(len(tools), 23)

    def test_3_events_poll(self):
        r = self.client.call("events_poll", {"limit": 5}, timeout=60)
        self.assertFalse(r["isError"], text_of(r))
        self.report["events"] = r["structuredContent"]["events"][-3:]

    def test_4_server_console_players(self):
        t0 = time.time()
        r = self.client.call("server_console", {"command": "players", "wait_s": 2}, timeout=90)
        self.assertFalse(r["isError"], text_of(r))
        lines = r["structuredContent"]["lines"]
        self.report["console_players"] = lines[-8:]
        self.report["console_s"] = round(time.time() - t0, 2)
        self.assertTrue(any("Players connected" in l or "player" in l.lower() for l in lines), lines)

    def test_5_run_lua_server(self):
        if not getattr(type(self), "live", False):
            self.report["run_lua_server"] = "skipped: bridge not live (server paused with no players online, or the mod is not loaded)"
            self.skipTest("bridge not live")
        r = self.client.call("run_lua_server", {"code": "return 1+1"}, timeout=60)
        self.assertFalse(r["isError"], text_of(r))
        self.assertEqual(text_of(r), "2")
        r = self.client.call("players_list", timeout=60)
        self.report["players_list"] = text_of(r)[:400]
        self.report["run_lua_server"] = "ok"


if __name__ == "__main__":
    unittest.main(verbosity=2)
