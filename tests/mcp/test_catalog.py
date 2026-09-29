"""The MCP catalogue and the Lua tools must agree: same names, same argument names (docs are the schema)."""

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MCP = os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP", "mcp")
LUA_SERVER = os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP", "42", "media", "lua", "server", "ZomboidMCP")
sys.path.insert(0, MCP)

import zmcp_catalog as catalog   # noqa: E402
import zomboid_mcp               # noqa: E402

# arguments the MCP process consumes itself before the call reaches the game
LOCAL_ONLY_ARGS = {"timeout_s", "png_path", "mesh_path"}


def lua_sources():
    out = {}
    for root, _, files in os.walk(LUA_SERVER):
        for fn in files:
            if fn.endswith(".lua"):
                path = os.path.join(root, fn)
                with open(path, "r", encoding="utf-8") as f:
                    out[os.path.relpath(path, LUA_SERVER)] = f.read()
    return out


def lua_tools(sources):
    """tool name -> (file, source text of that Z.tool(...) call up to the next Z.tool)"""
    tools = {}
    for path, text in sources.items():
        matches = list(re.finditer(r'Z\.tool\("([a-z_0-9]+)"', text))
        for i, m in enumerate(matches):
            end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
            tools[m.group(1)] = (path, text[m.start():end])
    return tools


class TestCatalogMatchesLua(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = lua_sources()
        cls.lua = lua_tools(cls.sources)

    def test_every_lua_tool_is_catalogued_or_internal(self):
        catalogued = set(catalog.GAME_NAMES)
        missing = sorted(set(self.lua) - catalogued - zomboid_mcp.GAME_INTERNAL_TOOLS)
        self.assertEqual(missing, [], "Lua tools without a catalogue entry (add a schema to zmcp_catalog.py): %s" % missing)

    def test_every_catalogued_game_tool_exists_in_lua(self):
        missing = sorted(set(catalog.GAME_NAMES) - set(self.lua))
        self.assertEqual(missing, [], "catalogue tools with no game side: %s" % missing)

    def test_mcp_and_game_names_agree(self):
        for t in catalog.TOOLS:
            if t["game"]:
                self.assertEqual(t["name"], t["game"], "one namespace: the MCP name must equal the game name")

    def test_schema_arguments_appear_in_the_lua_tool(self):
        """Every schema property is read by the Lua tool (a."<prop>" / "<prop>" / <prop> = in the tool body or its module)."""
        problems = []
        for t in catalog.TOOLS:
            if not t["game"]:
                continue
            path, body = self.lua[t["game"]]
            module = self.sources[path]
            shared = self.sources.get("Api/Common.lua", "")     # U.pos / U.posOrPlayer read x, y, z, player
            for prop in t["inputSchema"]["properties"]:
                if prop in LOCAL_ONLY_ARGS:
                    continue
                pat = r'(a\.%s\b|"%s"|\b%s\s*=)' % (re.escape(prop), re.escape(prop), re.escape(prop))
                if not (re.search(pat, body) or re.search(pat, module) or re.search(pat, shared)):
                    problems.append("%s.%s (not found in %s)" % (t["name"], prop, path))
        self.assertEqual(problems, [], "schema arguments the Lua never reads: %s" % problems)

    def test_descriptions_are_documentation(self):
        for t in catalog.TOOLS:
            d = t["description"]
            self.assertGreater(len(d), 80, t["name"])
            self.assertEqual(t["inputSchema"]["type"], "object", t["name"])
            for req in t["inputSchema"].get("required", []):
                self.assertIn(req, t["inputSchema"]["properties"], t["name"])
            for prop, spec in t["inputSchema"]["properties"].items():
                self.assertIn("description", spec, "%s.%s needs a description" % (t["name"], prop))
                self.assertIn("type", spec, "%s.%s needs a type" % (t["name"], prop))

    def test_local_tools_have_handlers(self):
        for t in catalog.TOOLS:
            if t["local"]:
                self.assertTrue(hasattr(zomboid_mcp.ZomboidMCP, "tool_" + t["local"]), t["name"])


if __name__ == "__main__":
    unittest.main()
