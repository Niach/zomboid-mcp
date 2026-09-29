"""Tests for zomboid_mcp.py against the fake game (no real game needed). Run: python3 -m unittest discover tests/mcp"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "mod", "Contents", "mods", "ZomboidMCP", "mcp"))

from fake_game import FakeGame                          # noqa: E402
from mcp_client import StdioClient, HttpClient, SERVER  # noqa: E402
import zmcp_catalog                                     # noqa: E402
import zmcp_game                                        # noqa: E402


def text_of(result):
    return "".join(c["text"] for c in result["content"] if c["type"] == "text")


class FakeGameCase(unittest.TestCase):
    """Base: fresh Lua dir with a fake game and a stdio server per test."""

    game_kwargs = {}
    server_args = []

    def setUp(self):
        self.lua_dir = tempfile.mkdtemp(prefix="zmcp_test_")
        self.game = FakeGame(self.lua_dir, **self.game_kwargs)
        self.game.write_status()
        self.game.start()
        self.client = StdioClient(["--lua-dir", self.lua_dir, "--timeout", "3"] + list(self.server_args))
        self.init = self.client.initialize()

    def tearDown(self):
        self.stderr = self.client.close()
        self.game.stop()
        shutil.rmtree(self.lua_dir, ignore_errors=True)


class TestProtocol(FakeGameCase):
    def test_initialize(self):
        r = self.init["result"]
        self.assertEqual(r["protocolVersion"], "2025-06-18")
        self.assertIn("tools", r["capabilities"])
        self.assertIn("resources", r["capabilities"])
        self.assertEqual(r["serverInfo"]["name"], "zomboid-mcp")
        self.assertIn("server paused", r["instructions"])

    def test_ping_and_unknown_method(self):
        self.assertEqual(self.client.request("ping")["result"], {})
        r = self.client.request("nope/what")
        self.assertEqual(r["error"]["code"], -32601)

    def test_parse_error_and_notifications(self):
        self.client.send_raw("{not json")
        self.client.notify("notifications/cancelled", {"requestId": 1})
        # server still alive
        self.assertEqual(self.client.request("ping")["result"], {})

    def test_tools_list_complete(self):
        tools = self.client.request("tools/list")["result"]["tools"]
        names = {t["name"] for t in tools}
        for expected in ("run_lua_server", "run_lua_client", "script_install", "script_list", "script_remove",
                         "status", "players_list", "wait_for", "events_poll", "api_search", "lua_examples",
                         "texture_upload", "model_upload", "spawn_item", "spawn_vehicle", "spawn_zombies",
                         "world_sprite", "object_3d_static", "object_3d_moving", "falling_items", "set_weather",
                         "set_time", "server_console"):
            self.assertIn(expected, names)
        # scripting-first: dropped tools (Guardian/Reborn, player edits, misc world ops) are not offered
        for dropped in ("heal", "cure", "god_mode", "snapshot", "restore", "guardian_config", "teleport", "give_item",
                        "place_object", "lua_eval_server", "client_exec", "module_install"):
            self.assertNotIn(dropped, names)
        # the primary tools point at the handbook and explain returns/errors/authority
        for name in ("run_lua_server", "run_lua_client", "script_install"):
            d = [t for t in tools if t["name"] == name][0]["description"]
            self.assertIn("zomboid engine handbook", d)
            self.assertIn("Authority", d) if name != "script_install" else None
            self.assertIn("rror", d)
        # every description states authority or is a local/discovery tool
        for t in tools:
            self.assertTrue(len(t["description"]) > 60, t["name"])
            self.assertEqual(t["inputSchema"]["type"], "object")
        # game-registered tools not in the catalogue are exposed as passthrough, with the game's description
        self.assertIn("custom_thing", names)
        ct = [t for t in tools if t["name"] == "custom_thing"][0]
        self.assertIn("fake tool custom_thing", ct["description"])
        # game tools that the catalogue maps under another name are not duplicated
        self.assertNotIn("lua_eval", names)
        self.assertNotIn("module_list", names)
        self.assertNotIn("tools_list", names)

    def test_resources(self):
        res = self.client.request("resources/list")["result"]["resources"]
        uris = {r["uri"] for r in res}
        self.assertIn("zomboid://docs/ENGINE_NOTES.md", uris)
        body = self.client.request("resources/read", {"uri": "zomboid://docs/ENGINE_NOTES.md"})["result"]
        self.assertIn("Engine notes", body["contents"][0]["text"])
        err = self.client.request("resources/read", {"uri": "zomboid://docs/nope.md"})
        self.assertIn("error", err)


class TestTools(FakeGameCase):
    def test_status_live(self):
        r = self.client.call("status")
        self.assertFalse(r["isError"])
        st = r["structuredContent"]
        self.assertEqual(st["bridge"], "live")
        self.assertEqual(st["players"][0]["user"], "niach")
        self.assertLess(st["heartbeat_age_s"], 5)

    def test_lua_eval_roundtrip_and_cleanup(self):
        r = self.client.call("run_lua_server", {"code": "return 1+1"})
        self.assertFalse(r["isError"])
        self.assertEqual(text_of(r), "2")
        self.assertEqual(self.game.calls[-1], ("lua_eval", {"code": "return 1+1"}))
        time.sleep(0.1)
        leftovers = [f for f in os.listdir(self.lua_dir) if f.startswith("zmcp_req_") or f.startswith("zmcp_res_")]
        self.assertEqual(leftovers, [])

    def test_sequence_and_ordering(self):
        for i in range(5):
            r = self.client.call("custom_thing", {"i": i})
            self.assertEqual(r["structuredContent"]["args"]["i"], i)
        self.assertEqual([a["i"] for t, a in self.game.calls if t == "custom_thing"], [0, 1, 2, 3, 4])
        # 5 requests plus one tools_list (the game's descriptions for passthrough tools, cached afterwards)
        self.assertEqual(self.game.next_req, 5 + 1 + 1)
        # PROTOCOL.md: every request carries its number and a timestamp
        for req in self.game.requests_seen:
            self.assertIn("n", req)
            self.assertAlmostEqual(req["t"], time.time(), delta=30)
        self.assertEqual([r["n"] for r in self.game.requests_seen], [1, 2, 3, 4, 5, 6])
        self.assertEqual(self.game.requests_seen[0]["tool"], "tools_list")

    def test_request_json_is_ascii(self):
        r = self.client.call("custom_thing", {"text": "Zoë ☃"})
        self.assertFalse(r["isError"])
        self.assertEqual(r["structuredContent"]["args"]["text"], "Zoë ☃")
        self.assertEqual(self.game.requests_seen[-1]["args"]["text"], "Zoë ☃")

    def test_game_error_is_tool_error(self):
        r = self.client.call("run_lua_server", {"code": "error('kaboom')"})
        self.assertTrue(r["isError"])
        self.assertIn("kaboom", text_of(r))

    def test_unknown_game_tool_hint(self):
        r = self.client.call("spawn_vehicle", {"script": "Base.CarNormal", "x": 1, "y": 2})
        self.assertTrue(r["isError"])
        self.assertIn("does not implement", text_of(r))
        self.assertIn("run_lua_server", text_of(r))

    def test_argument_validation(self):
        r = self.client.call("spawn_item", {"player": "x"})
        self.assertTrue(r["isError"])
        self.assertIn("missing required argument 'item'", text_of(r))
        r = self.client.call("spawn_zombies", {"x": 1, "y": 1, "count": 500})
        self.assertIn("<= 50", text_of(r))
        r = self.client.call("set_weather", {"mode": "snow"})
        self.assertIn("one of", text_of(r))
        r = self.client.call("spawn_item", {"item": "Base.Axe", "x": 1.0, "y": 2.0, "z": 0})   # integral floats are fine
        self.assertNotIn("must be a", text_of(r))
        r = self.client.request("tools/call", {"name": 5})
        self.assertEqual(r["error"]["code"], -32602)

    def test_large_args_become_blob_files(self):
        big = "A" * 200000
        r = self.client.call("blob_check", {"png_base64": big, "id": "snail"})
        self.assertFalse(r["isError"], text_of(r))
        sc = r["structuredContent"]
        self.assertEqual(sc["id"], 5)
        self.assertEqual(sc["png_base64_file"]["bytes"], 200000)
        self.assertTrue(sc["png_base64_file"]["file"].startswith("zmcp_blob_"))
        time.sleep(0.1)
        self.assertEqual([f for f in os.listdir(self.lua_dir) if f.startswith("zmcp_blob_")], [])

    def test_blob_kept_when_requested(self):
        r = self.client.call("keep", {"data": "B" * 100000})
        self.assertFalse(r["isError"])
        blobs = [f for f in os.listdir(self.lua_dir) if f.startswith("zmcp_blob_")]
        self.assertEqual(len(blobs), 1)

    def test_events_poll_cursor(self):
        r = self.client.call("events_poll")
        ev = r["structuredContent"]
        kinds = [e["kind"] for e in ev["events"]]
        self.assertIn("bridge_loaded", kinds)
        cursor = ev["cursor"]
        self.game.event("death", {"user": "niach"})
        self.game.event("join", {"user": "bob"})
        r = self.client.call("events_poll", {"cursor": cursor})
        ev2 = r["structuredContent"]
        self.assertEqual([e["kind"] for e in ev2["events"]], ["death", "join"])
        # session cursor continues automatically
        r = self.client.call("events_poll")
        self.assertEqual(r["structuredContent"]["events"], [])
        self.game.event("join", {"user": "carol"})
        r = self.client.call("events_poll", {"kinds": ["death"]})
        self.assertEqual(r["structuredContent"]["events"], [])

    def test_script_install_fallback_to_run_file(self):
        r = self.client.call("script_install", {"name": "hello", "code": "print('hi')"})
        self.assertFalse(r["isError"], text_of(r))
        sc = r["structuredContent"]
        self.assertFalse(sc["persistent"])
        self.assertEqual(sc["result"]["ran"], "zmcp_mod_hello.lua")
        self.assertTrue(os.path.exists(os.path.join(self.lua_dir, "zmcp_mod_hello.lua")))
        r = self.client.call("script_install", {"name": "../evil", "code": "x"})
        self.assertTrue(r["isError"])

    def test_api_search_missing_index_is_clear(self):
        r = self.client.call("api_search", {"query": "addLamppost"})
        self.assertFalse(r["isError"])
        self.assertIn("not available", r["structuredContent"]["error"])

    def test_server_console_unconfigured(self):
        r = self.client.call("server_console", {"command": "players"})
        self.assertTrue(r["isError"])
        self.assertIn("--console-container", text_of(r))

    def test_wait_for_immediate(self):
        r = self.client.call("wait_for", {"player": "Cool Jesus", "timeout_s": 5})
        self.assertFalse(r["isError"], text_of(r))
        self.assertEqual(r["structuredContent"]["bridge"], "live")

    def test_concurrent_ping_during_slow_call(self):
        import threading
        results = {}

        def slow():
            results["slow"] = self.client.call("slow", {"seconds": 1.0}, timeout=10)
        th = threading.Thread(target=slow)
        th.start()
        time.sleep(0.2)
        t0 = time.time()
        self.assertEqual(self.client.request("ping")["result"], {})
        self.assertLess(time.time() - t0, 0.8)   # ping answered while the tool call is in flight
        th.join()
        self.assertFalse(results["slow"]["isError"])


class TestPaused(FakeGameCase):
    game_kwargs = {"players": []}

    def test_paused_server_message(self):
        self.game.paused = True
        time.sleep(0.3)
        # heartbeat goes stale only after STALE_AFTER_S; fake it by back-dating the status file
        st = json.load(open(os.path.join(self.lua_dir, "zmcp_status.json")))
        st["t"] = int(time.time()) - 60
        json.dump(st, open(os.path.join(self.lua_dir, "zmcp_status.json"), "w"))
        r = self.client.call("status")
        self.assertEqual(r["structuredContent"]["bridge"], "paused")
        r = self.client.call("run_lua_server", {"code": "return 1", "timeout_s": 1})
        self.assertTrue(r["isError"])
        self.assertIn("server paused (no players online)", text_of(r))
        # the request was cleaned up, not left for later
        self.assertEqual([f for f in os.listdir(self.lua_dir) if f.startswith("zmcp_req_")], [])
        r = self.client.call("wait_for", {"timeout_s": 1})
        self.assertTrue(r["isError"])
        self.assertIn("timed out", text_of(r))

    def test_wait_for_until_player_joins(self):
        import threading

        def join_later():
            time.sleep(0.6)
            self.game.players.append({"user": "bob", "name": "Bob B", "x": 1, "y": 2, "z": 0, "dead": False, "health": 90})
        threading.Thread(target=join_later, daemon=True).start()
        r = self.client.call("wait_for", {"player": "bob", "timeout_s": 10})
        self.assertFalse(r["isError"], text_of(r))
        self.assertEqual(r["structuredContent"]["players"][0]["user"], "bob")


class TestResync(FakeGameCase):
    game_kwargs = {"next_req": 41}

    def test_starts_from_game_counter_and_resyncs_after_restart(self):
        r = self.client.call("custom_thing", {"a": 1})
        self.assertFalse(r["isError"])
        self.assertEqual([q["n"] for q in self.game.requests_seen], [41, 42])   # tools_list, custom_thing
        # simulate a server restart: new bootId and a counter far away from ours
        self.game.next_req = 1000
        self.game.boot_id = "restarted"
        self.game.write_status()
        time.sleep(0.3)
        r = self.client.call("custom_thing", {"a": 2})
        self.assertFalse(r["isError"], text_of(r))
        self.assertEqual(self.game.calls[-1], ("custom_thing", {"a": 2}))
        self.assertEqual(self.game.requests_seen[-1]["n"], 1000)
        # and a restart that comes back with a LOWER counter (ModData saved a minute ago)
        self.game.next_req = 3
        self.game.boot_id = "restarted-again"
        self.game.write_status()
        time.sleep(0.3)
        r = self.client.call("custom_thing", {"a": 3})
        self.assertFalse(r["isError"], text_of(r))
        self.assertEqual(self.game.requests_seen[-1]["n"], 3)

    def test_resync_uses_highest_existing_request_and_drops_old_leftovers(self):
        # a leftover request written by a crashed client ahead of nextReq, plus a very old pair
        self.game.paused = True
        time.sleep(0.1)
        with open(os.path.join(self.lua_dir, "zmcp_req_45.json"), "w") as f:
            f.write(json.dumps({"n": 45, "t": time.time(), "tool": "echo", "args": {}}))
        old = os.path.join(self.lua_dir, "zmcp_res_7.json")
        with open(old, "w") as f:
            f.write("{}\n")
        os.utime(old, (time.time() - 1000, time.time() - 1000))
        client2 = StdioClient(["--lua-dir", self.lua_dir, "--timeout", "3"])
        client2.initialize()
        self.game.paused = False
        r = client2.call("custom_thing", {"b": 1})
        client2.close()
        self.assertFalse(r["isError"], text_of(r))
        # the game executes the leftover 45 via its gap probe; we start at max(nextReq=41, 45 + 1) = 46
        self.assertEqual([q["n"] for q in self.game.requests_seen], [45, 46, 47])
        self.assertFalse(os.path.exists(old))                      # stale leftover removed

    def test_not_running(self):
        os.remove(os.path.join(self.lua_dir, "zmcp_status.json"))
        self.game.paused = True
        time.sleep(0.1)
        if os.path.exists(os.path.join(self.lua_dir, "zmcp_status.json")):
            os.remove(os.path.join(self.lua_dir, "zmcp_status.json"))
        r = self.client.call("status")
        self.assertEqual(r["structuredContent"]["bridge"], "not_running")
        client2 = StdioClient(["--lua-dir", self.lua_dir, "--timeout", "1"])
        client2.initialize()
        r = client2.call("players_list")
        client2.close()
        self.assertTrue(r["isError"])
        self.assertIn("not running", text_of(r))


class TestLegacyBridge(FakeGameCase):
    """Bridge 0.1.0 (main): no trailing newline, request file blanked, status.tools is a count."""

    game_kwargs = {"legacy": True}

    def test_roundtrip_and_passthrough_discovery(self):
        r = self.client.call("run_lua_server", {"code": "return 1+1"})
        self.assertFalse(r["isError"], text_of(r))
        self.assertEqual(text_of(r), "2")
        names = {t["name"] for t in self.client.request("tools/list")["result"]["tools"]}
        self.assertIn("custom_thing", names)      # discovered through tools_list


class TestShellScripts(FakeGameCase):
    """Run the ssh transport's real shell snippets locally (sh -c) against the fake game."""

    def setUp(self):
        FakeGameCase.setUp(self)
        self.tr = zmcp_game.SshTransport(self.lua_dir, "unused-host")

        def local_sh(script, stdin=None, timeout=None):
            p = subprocess.run(["sh", "-c", script], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")
        self.tr.sh = local_sh

    def test_roundtrip_script(self):
        bridge = zmcp_game.GameBridge(self.tr, timeout_s=3)
        self.assertEqual(bridge.call("lua_eval", {"code": "return 1+1"}), 2)
        self.assertEqual(bridge.call("echo", {"x": 1}), {"x": 1})
        self.assertEqual(bridge.last_status["version"], "0.2.0-fake")
        with self.assertRaises(zmcp_game.GameError) as cm:
            bridge.call("fail", {"message": "nope"})
        self.assertIn("nope", str(cm.exception))
        leftovers = [f for f in os.listdir(self.lua_dir) if f.startswith(("zmcp_req_", "zmcp_res_"))]
        self.assertEqual(leftovers, [])

    def test_timeout_script_and_withdraw(self):
        self.game.paused = True
        time.sleep(0.1)
        bridge = zmcp_game.GameBridge(self.tr, timeout_s=0.5)
        t0 = time.time()
        with self.assertRaises(zmcp_game.GameError):
            bridge.call("echo", {})
        self.assertLess(time.time() - t0, 5)
        self.assertEqual([f for f in os.listdir(self.lua_dir) if f.startswith("zmcp_req_")], [])

    def test_read_from_list_and_console_scripts(self):
        data, size = self.tr.read_from("zmcp_events.jsonl", 0)
        self.assertEqual(size, len(data))
        self.assertIn(b"bridge_loaded", data)
        tail, size2 = self.tr.read_from("zmcp_events.jsonl", size - 3)
        self.assertEqual(len(tail), 3)
        self.assertEqual(self.tr.read_from("missing.txt", 0), (b"", 0))
        with open(os.path.join(self.lua_dir, "zmcp_req_99.json"), "w") as f:
            f.write("{}")
        files, now = self.tr.list_protocol_files()
        self.assertIn("zmcp_req_99.json", [n for n, _ in files])
        self.assertAlmostEqual(now, time.time(), delta=5)
        # console: a FIFO-less "fifo" file and a log the command appends to
        fifo = os.path.join(self.lua_dir, "fifo.txt")
        logf = os.path.join(self.lua_dir, "server-console.txt")
        with open(logf, "w") as f:
            f.write("old line\n")
        import threading

        def echo_back():
            time.sleep(0.3)
            with open(fifo) as f, open(logf, "a") as out:
                out.write("> " + f.read())
        threading.Thread(target=echo_back).start()
        out = self.tr.console("players", None, fifo, logf, 0.8)
        self.assertEqual(out.strip(), "> players")


class TestIndex(unittest.TestCase):
    """api_search / lua_examples on a small fixture in the docs/API_INDEX.md schema."""

    @classmethod
    def setUpClass(cls):
        import gzip
        cls.dir = tempfile.mkdtemp(prefix="zmcp_index_")
        api = {
            "schema": 1, "game_version": "42.21", "stats": {"classes": 2},
            "globals": [{"n": "getTexture", "p": ["String"], "pn": ["filename"], "r": "Texture"},
                        {"n": "addZombiesInOutfit", "p": ["int", "int", "int", "int", "String", "Integer"],
                         "pn": ["x", "y", "z", "n", "outfit", "female"], "r": "ArrayList<IsoZombie>"}],
            "classes": {
                "zombie.iso.IsoCell": {"name": "IsoCell", "fqn": "zombie.iso.IsoCell", "kind": "class", "exposed": True,
                                       "extends": None, "implements": [], "ctors": [], "fields": [],
                                       "methods": [{"n": "addLamppost", "p": ["int", "int", "int", "float", "float", "float", "int"],
                                                    "pn": ["x", "y", "z", "r", "g", "b", "rad"], "r": "IsoLightSource"}]},
                "zombie.iso.IsoGridSquare": {"name": "IsoGridSquare", "fqn": "zombie.iso.IsoGridSquare", "kind": "class",
                                             "exposed": True, "extends": "zombie.iso.IsoObject", "implements": [],
                                             "ctors": [{"p": ["IsoCell", "int", "int", "int"], "pn": ["cell", "x", "y", "z"]}],
                                             "fields": [{"n": "chunk", "t": "IsoChunk"}],
                                             "methods": [{"n": "transmitAddObjectToSquare", "p": ["IsoObject", "int"],
                                                          "pn": ["obj", "index"], "r": "void"}]},
                "zombie.iso.IsoObject": {"name": "IsoObject", "fqn": "zombie.iso.IsoObject", "kind": "class", "exposed": False,
                                         "extends": None, "implements": [], "ctors": [], "fields": [],
                                         "methods": [{"n": "getSprite", "p": [], "r": "IsoSprite"}]},
            },
        }
        ex = {
            "schema": 1, "game_version": "42.21", "files": ["shared/a.lua", "client/b.lua"],
            "events": ["OnTick"],
            "defs": {"ISCutHair:perform": [[1, 10, ""]], "luautils.round": [[0, 5, "num, idp"]]},
            "calls": {"setHairModel": [[1, 20, "visual:setHairModel(x)"]], "Events.OnTick": [[0, 1, "Events.OnTick.Add(f)"]]},
            "curated": {"addLamppost": [{"lua": "getCell():addLamppost(x, y, z, 1, 1, 1, 10)", "note": "n"}]},
        }
        with gzip.open(os.path.join(cls.dir, "api_index.json.gz"), "wb") as f:
            f.write(json.dumps(api).encode())
        with gzip.open(os.path.join(cls.dir, "lua_examples.json.gz"), "wb") as f:
            f.write(json.dumps(ex).encode())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def index(self):
        import zmcp_index
        return zmcp_index.ApiIndex(self.dir, lua_dirs=[])

    def test_search_ranking_and_hints(self):
        ix = self.index()
        r = ix.search("addLamppost")
        self.assertEqual(r["total"], 1)
        h = r["results"][0]
        self.assertEqual(h["signature"], "IsoLightSource IsoCell:addLamppost(int x, int y, int z, float r, float g, float b, int rad)")
        self.assertEqual(h["lua"], "obj:addLamppost(x, y, z, r, g, b, rad)")
        r = ix.search("getTexture", kind="global")
        self.assertEqual(r["results"][0]["lua"], "getTexture(filename)")
        r = ix.search("IsoGridSquare")
        kinds = [h["kind"] for h in r["results"]]
        self.assertIn("class", kinds)
        self.assertIn("ctor", kinds)
        self.assertEqual([h for h in r["results"] if h["kind"] == "ctor"][0]["lua"], "IsoGridSquare.new(cell, x, y, z)")
        # Class:member scope includes the superclass chain and flags unexposed classes
        r = ix.search("IsoGridSquare:getSprite")
        self.assertEqual(r["total"], 1)
        self.assertEqual(r["results"][0]["inherited_from"], "zombie.iso.IsoObject")
        self.assertIn("warning", r["results"][0])
        r = ix.search("^add.*Outfit$")
        self.assertEqual(r["results"][0]["name"], "addZombiesInOutfit")
        self.assertEqual(ix.search("zzz")["total"], 0)

    def test_examples(self):
        ix = self.index()
        r = ix.lua_examples("setHairModel")
        self.assertEqual(r["calls"][0]["file"], "client/b.lua")
        r = ix.lua_examples("ISCutHair")
        self.assertEqual(r["defs"][0]["name"], "ISCutHair:perform")
        r = ix.lua_examples("addlamppost")
        self.assertEqual(len(r["curated"]), 1)
        r = ix.lua_examples("Events.OnTick")
        self.assertEqual(len(r["calls"]), 1)
        r = ix.lua_examples("Hair")
        self.assertEqual(r["related"], ["setHairModel"])

    def test_missing_index_message(self):
        import zmcp_index
        ix = zmcp_index.ApiIndex(os.path.join(self.dir, "nope"), lua_dirs=[])
        self.assertIn("not available", ix.search("x")["error"])
        self.assertIn("not available", ix.lua_examples("x")["error"])

    def test_through_the_server(self):
        lua_dir = tempfile.mkdtemp(prefix="zmcp_ix_")
        client = StdioClient(["--lua-dir", lua_dir, "--api-index", self.dir])
        client.initialize()
        try:
            r = client.call("api_search", {"query": "transmitAddObjectToSquare"})
            self.assertFalse(r["isError"])
            self.assertEqual(r["structuredContent"]["results"][0]["kind"], "method")
            r = client.call("lua_examples", {"query": "addLamppost"})
            self.assertEqual(len(r["structuredContent"]["curated"]), 1)
            r = client.call("status")
            self.assertEqual(r["structuredContent"]["api_index"]["api_index"]["game_version"], "42.21")
        finally:
            client.close()
            shutil.rmtree(lua_dir, ignore_errors=True)

    @unittest.skipUnless(os.path.exists(os.path.join(os.path.dirname(SERVER), "api_index.json.gz")), "real index not built")
    def test_real_index_acceptance_symbols(self):
        import zmcp_index
        ix = zmcp_index.ApiIndex(os.path.dirname(SERVER), lua_dirs=[])
        for sym in ("addLamppost", "transmitAddObjectToSquare", "addZombiesInOutfit", "getTexture", "setHairModel"):
            hits = [h for h in ix.search(sym, limit=50)["results"] if h["name"] == sym and h["kind"] in ("method", "global")]
            self.assertTrue(hits, sym)
            ex = ix.lua_examples(sym)
            self.assertTrue(ex["calls"] or ex["curated"], sym)


class TestHttp(unittest.TestCase):
    def setUp(self):
        self.lua_dir = tempfile.mkdtemp(prefix="zmcp_http_")
        self.game = FakeGame(self.lua_dir)
        self.game.write_status()
        self.game.start()
        self.proc = subprocess.Popen([sys.executable, SERVER, "--http", "0", "--lua-dir", self.lua_dir, "--timeout", "3"],
                                     stderr=subprocess.PIPE)
        line = self.proc.stderr.readline().decode()
        self.assertIn("listening on", line)
        self.url = line.split("listening on ", 1)[1].split(" ")[0]
        self.client = HttpClient(self.url)

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)
        self.game.stop()
        shutil.rmtree(self.lua_dir, ignore_errors=True)

    def test_http_roundtrip(self):
        status, headers, body = self.client.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                                                   "clientInfo": {"name": "t", "version": "0"}})
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["protocolVersion"], "2025-03-26")
        self.assertTrue(headers.get("Mcp-Session-Id"))
        status, _, body = self.client.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual(status, 202)
        self.assertIsNone(body)
        status, _, body = self.client.request("tools/list")
        self.assertGreaterEqual(len(body["result"]["tools"]), 23)
        r = self.client.call("run_lua_server", {"code": "return 1+1"})
        self.assertEqual(text_of(r), "2")
        r = self.client.call("status")
        self.assertEqual(r["structuredContent"]["bridge"], "live")

    def test_http_rejects_bad_origin_and_get(self):
        status, _, _ = self.client.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, headers={"Origin": "http://evil.example"})
        self.assertEqual(status, 403)
        status, _, _ = self.client.post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, headers={"Origin": "http://localhost:3000"})
        self.assertEqual(status, 200)
        req = urllib.request.Request(self.url, method="GET")
        try:
            urllib.request.urlopen(req, timeout=5)
            self.fail("GET should be rejected")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 405)

    def test_http_binds_localhost_only(self):
        port = int(self.url.rsplit(":", 1)[1].split("/")[0])
        # the socket is bound to 127.0.0.1: connecting to another local address must fail
        addrs = [a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)]
        for addr in addrs:
            if addr.startswith("127."):
                continue
            s = socket.socket()
            s.settimeout(1)
            self.assertNotEqual(s.connect_ex((addr, port)), 0, addr)
            s.close()


class TestUnits(unittest.TestCase):
    def test_catalogue_schemas_are_sane(self):
        for t in zmcp_catalog.TOOLS:
            self.assertTrue(t["game"] or t["local"], t["name"])
            json.dumps(t["inputSchema"])
            for req in t["inputSchema"].get("required", []):
                self.assertIn(req, t["inputSchema"]["properties"], t["name"])
        self.assertEqual(len({t["name"] for t in zmcp_catalog.TOOLS}), len(zmcp_catalog.TOOLS))

    def test_ssh_transport_command_shape(self):
        tr = zmcp_game.SshTransport("/data/Lua", "root@example", port=2222)
        base = tr._ssh_base()
        self.assertIn("ControlMaster=auto", base)
        self.assertIn("ControlPersist=10m", base)
        self.assertEqual(base[-1], "root@example")
        self.assertIn("2222", base)
        self.assertEqual(tr.resolve("x.json"), "/data/Lua/x.json")
        self.assertEqual(tr.resolve("/abs/server-console.txt"), "/abs/server-console.txt")

    def test_ssh_roundtrip_parsing(self):
        """Feed the shell script output format through the parser without a network."""
        tr = zmcp_game.SshTransport("/data/Lua", "h")
        captured = {}

        def fake_sh(script, stdin=None, timeout=None):
            captured["script"] = script
            captured["stdin"] = stdin
            return 0, b'__ZMCP_OK__\n{"ok":true,"result":7}\n__ZMCP_STATUS__\n{"t":5,"nextReq":9}\n__ZMCP_NOW__ 6', ""
        tr.sh = fake_sh
        res, status, now = tr.roundtrip(8, '{"tool":"x"}', 2.5)
        self.assertEqual(json.loads(res), {"ok": True, "result": 7})
        self.assertEqual(json.loads(status), {"t": 5, "nextReq": 9})
        self.assertEqual(now, 6.0)
        self.assertIn("/data/Lua/zmcp_req_8.json", captured["script"])
        self.assertEqual(captured["stdin"], b'{"tool":"x"}')
        tr.sh = lambda s, stdin=None, timeout=None: (0, b'__ZMCP_TIMEOUT__\n__ZMCP_STATUS__\n\n__ZMCP_NOW__ 6', "")
        res, status, now = tr.roundtrip(9, "{}", 1)
        self.assertIsNone(res)
        self.assertIsNone(status)

    def test_load_env_file(self):
        import zomboid_mcp
        fd, path = tempfile.mkstemp()
        os.write(fd, b"# c\nZMCP_TEST_A=/vol\nZMCP_TEST_B=$ZMCP_TEST_A/Lua\n")
        os.close(fd)
        zomboid_mcp.load_env_file(path)
        os.remove(path)
        self.assertEqual(os.environ["ZMCP_TEST_B"], "/vol/Lua")

    def test_validate_args_unknown_key(self):
        import zomboid_mcp
        schema = zmcp_catalog.BY_NAME["players_list"]["inputSchema"]
        with self.assertRaises(ValueError):
            zomboid_mcp.validate_args(schema, {"plyer": "x"})
        zomboid_mcp.validate_args(schema, {})


if __name__ == "__main__":
    unittest.main()
