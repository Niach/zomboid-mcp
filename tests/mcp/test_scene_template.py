"""scene_template is answered by the MCP process from examples/: every advertised template exists and is valid Lua."""

import os
import sys
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP", "mcp"))

import zomboid_mcp  # noqa: E402


class TestSceneTemplate(unittest.TestCase):
    def setUp(self):
        self.mcp = zomboid_mcp.ZomboidMCP(bridge=None, index=None)

    def test_list_and_fetch(self):
        listing = self.mcp.tool_scene_template({}, None)
        names = {t["name"] for t in listing["templates"]}
        self.assertEqual(names, {"merchant", "supply_drop", "meteor_shower", "haunted_house", "companion", "flappy"})
        for name in sorted(names):
            r = self.mcp.tool_scene_template({"name": name}, None)
            self.assertEqual(r["name"], name)
            self.assertIn("kind", r)
            self.assertEqual(r["tool"], "app_start" if name == "flappy" else "scene_start")
            self.assertGreater(len(r["code"]), 500, name)
            self.assertTrue(os.path.isfile(r["path"]))
        with self.assertRaises(zomboid_mcp.GameError):
            self.mcp.tool_scene_template({"name": "nope"}, None)

    def test_examples_are_valid_lua(self):
        try:
            from lupa import lua51
        except ImportError:
            self.skipTest("lupa not installed")
        rt = lua51.LuaRuntime()
        check = rt.eval("function(s, n) local f, e = loadstring(s, n) return f ~= nil, e end")
        for kind in ("scenes", "apps"):
            d = os.path.join(ROOT, "examples", kind)
            for fn in sorted(os.listdir(d)):
                ok, err = check(open(os.path.join(d, fn)).read(), "=" + fn)
                self.assertTrue(ok, "%s: %s" % (fn, err))


if __name__ == "__main__":
    unittest.main()
