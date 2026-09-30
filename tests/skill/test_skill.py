"""The zomboid-engine skill (mod/Contents/mods/ZomboidMCP/skill/) must stay correct on its own:

- SKILL.md has valid frontmatter (name zomboid-engine, a description) and stays short (the depth is in the guides)
- every relative link in the skill resolves (a few targets owned by issues still in flight are allowed to be missing)
- every ```lua block compiles under Lua 5.1 (lupa) and avoids the Kahlua traps (next(), io., bit., tostring())
- every ```json block that is an MCP tool call ({"tool": ..., "args": {...}}) uses a catalogued tool with valid
  argument names, required arguments present and enum values valid (the recipes are the four acceptance sequences)
- the generated API reference is current (tools/gen_api_reference.py --check) and under its size budget
- every catalogued MCP tool is mentioned somewhere in the skill (the skill routes to the complete catalogue)
"""

import os
import re
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MOD = os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP")
SKILL = os.path.join(MOD, "skill")
sys.path.insert(0, os.path.join(MOD, "mcp"))

import zmcp_catalog as catalog  # noqa: E402

# links whose targets are written by other issues (ZOM-10: scenes-and-apps.md + examples/apps/flappy.lua)
PENDING_TARGETS = {
    "skill/guides/scenes-and-apps.md",
    "examples/apps/flappy.lua",
    "examples/scenes",
}
MAX_SKILL_LINES = 200
REFERENCE_BUDGET = 1_500_000
LUA_TRAPS = [
    (re.compile(r"(?<![\w.])next\s*\("), "next() does not exist in Kahlua (use `for _ in pairs(t) do ... end`)"),
    (re.compile(r"(?<![\w.])io\."), "the io library does not exist in Kahlua (use getFileWriter/getFileReader)"),
    (re.compile(r"(?<![\w.])bit\."), "bit operations do not exist in Kahlua (use arithmetic)"),
    (re.compile(r"(?<![\w.])tostring\(\s*\)"), "tostring() without an argument throws in Kahlua"),
    (re.compile(r"(?<![\w.])goto\s"), "goto is Lua 5.2+, Kahlua is 5.1"),
]
FENCE = re.compile(r"^```([\w-]*)[ \t]*\n(.*?)^```[ \t]*$", re.M | re.S)
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def md_files():
    out = []
    for root, _, files in os.walk(SKILL):
        for fn in sorted(files):
            if fn.endswith(".md"):
                out.append(os.path.join(root, fn))
    return sorted(out)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def blocks(path, lang):
    text = read(path)
    for m in FENCE.finditer(text):
        if m.group(1) == lang:
            line = text.count("\n", 0, m.start()) + 1
            yield line, m.group(2)


def rel(path):
    return os.path.relpath(path, ROOT)


class TestFrontmatter(unittest.TestCase):
    def test_skill_md_frontmatter_and_length(self):
        path = os.path.join(SKILL, "SKILL.md")
        text = read(path)
        m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
        self.assertIsNotNone(m, "SKILL.md must start with a --- frontmatter block")
        fm = dict(re.findall(r"^([A-Za-z_]+):\s*(.*)$", m.group(1), re.M))
        self.assertEqual(fm.get("name"), "zomboid-engine")
        self.assertTrue(len(fm.get("description", "")) > 80, "description must be a real trigger sentence")
        for word in ("Project Zomboid", "hack the simulation"):
            self.assertIn(word, fm["description"], "description must trigger on %r" % word)
        lines = text.count("\n") + 1
        self.assertLessEqual(lines, MAX_SKILL_LINES, "SKILL.md is %d lines; keep the depth in guides/" % lines)


class TestLinks(unittest.TestCase):
    def test_every_relative_link_resolves(self):
        bad = []
        for path in md_files():
            text = read(path)
            for m in LINK.finditer(text):
                target = m.group(1).split("#", 1)[0]
                if not target or "://" in target or target.startswith("mailto:"):
                    continue
                full = os.path.normpath(os.path.join(os.path.dirname(path), target))
                if os.path.exists(full):
                    continue
                if os.path.relpath(full, MOD) in PENDING_TARGETS or os.path.relpath(full, ROOT) in PENDING_TARGETS:
                    continue
                bad.append("%s -> %s" % (rel(path), m.group(1)))
        self.assertEqual(bad, [], "broken links:\n" + "\n".join(bad))

    def test_no_repo_internal_paths_in_pending(self):
        """Pending targets must be inside the mod or the repo, nothing else."""
        for t in PENDING_TARGETS:
            self.assertFalse(t.startswith("/"), t)


class TestLuaBlocks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from lupa import lua51
        cls.rt = lua51.LuaRuntime()
        cls.check = cls.rt.eval("function(s, n) local f, e = loadstring(s, n) return f ~= nil, e end")

    def test_lua_blocks_compile_under_lua51(self):
        bad, count = [], 0
        for path in md_files():
            for line, code in blocks(path, "lua"):
                count += 1
                ok, err = self.check(code, "=%s:%d" % (rel(path), line))
                if not ok:
                    bad.append("%s:%d: %s" % (rel(path), line, err))
        self.assertGreater(count, 40, "expected many tested snippets")
        self.assertEqual(bad, [], "Lua blocks that do not compile:\n" + "\n".join(bad))

    def test_lua_blocks_avoid_kahlua_traps(self):
        bad = []
        for path in md_files():
            for line, code in blocks(path, "lua"):
                stripped = re.sub(r"--\[\[.*?\]\]", "", code, flags=re.S)
                stripped = re.sub(r"--[^\n]*", "", stripped)          # comments may mention the traps
                stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', stripped)  # strings too
                for rx, why in LUA_TRAPS:
                    if rx.search(stripped):
                        bad.append("%s:%d: %s" % (rel(path), line, why))
        self.assertEqual(bad, [], "\n".join(bad))


def validate_args(schema, args, where, errors):
    props = schema.get("properties", {})
    for req in schema.get("required", []):
        if req not in args:
            errors.append("%s: missing required argument '%s'" % (where, req))
    for k, v in args.items():
        spec = props.get(k)
        if spec is None:
            if schema.get("additionalProperties", False):
                continue
            errors.append("%s: unknown argument '%s' (known: %s)" % (where, k, ", ".join(sorted(props))))
            continue
        t = spec.get("type")
        if "enum" in spec and v not in spec["enum"]:
            errors.append("%s: '%s' must be one of %s" % (where, k, spec["enum"]))
        elif t == "string" and not isinstance(v, str):
            errors.append("%s: '%s' must be a string" % (where, k))
        elif t == "integer" and (not isinstance(v, int) or isinstance(v, bool)):
            errors.append("%s: '%s' must be an integer" % (where, k))
        elif t == "number" and (not isinstance(v, (int, float)) or isinstance(v, bool)):
            errors.append("%s: '%s' must be a number" % (where, k))
        elif t == "boolean" and not isinstance(v, bool):
            errors.append("%s: '%s' must be a boolean" % (where, k))
        elif t == "array" and not isinstance(v, list):
            errors.append("%s: '%s' must be an array" % (where, k))
        elif t == "object" and not isinstance(v, dict):
            errors.append("%s: '%s' must be an object" % (where, k))
        if t == "array" and isinstance(v, list) and spec.get("items", {}).get("type") == "object":
            for i, item in enumerate(v):
                if isinstance(item, dict):
                    validate_args(spec["items"], item, "%s.%s[%d]" % (where, k, i), errors)
        if "minimum" in spec and isinstance(v, (int, float)) and not isinstance(v, bool) and v < spec["minimum"]:
            errors.append("%s: '%s' below minimum %s" % (where, k, spec["minimum"]))
        if "maximum" in spec and isinstance(v, (int, float)) and not isinstance(v, bool) and v > spec["maximum"]:
            errors.append("%s: '%s' above maximum %s" % (where, k, spec["maximum"]))


class TestToolCalls(unittest.TestCase):
    """```json blocks of the form {"tool": "...", "args": {...}} (or a list of them) are checked against the catalogue."""

    def test_json_tool_calls_match_the_catalogue(self):
        import json
        errors, count = [], 0
        for path in md_files():
            for line, code in blocks(path, "json"):
                try:
                    data = json.loads(code)
                except ValueError as e:
                    errors.append("%s:%d: invalid JSON: %s" % (rel(path), line, e))
                    continue
                calls = data if isinstance(data, list) else [data]
                for i, call in enumerate(calls):
                    if not isinstance(call, dict) or "tool" not in call:
                        continue
                    count += 1
                    where = "%s:%d[%d] %s" % (rel(path), line, i, call.get("tool"))
                    tool = catalog.BY_NAME.get(call["tool"])
                    if tool is None:
                        errors.append("%s: unknown tool" % where)
                        continue
                    args = call.get("args", {})
                    if not isinstance(args, dict):
                        errors.append("%s: args must be an object" % where)
                        continue
                    validate_args(tool["inputSchema"], args, where, errors)
        self.assertGreater(count, 15, "expected the acceptance sequences as json tool calls")
        self.assertEqual(errors, [], "\n".join(errors))

    def test_every_catalogued_tool_is_documented(self):
        text = "\n".join(read(p) for p in md_files())
        missing = [t["name"] for t in catalog.TOOLS if "`%s`" % t["name"] not in text]
        self.assertEqual(missing, [], "tools the skill never mentions: %s" % missing)


class TestPythonBlocks(unittest.TestCase):
    """```python blocks starting with `# test: python` (the .x mesh generator) run in a temp dir and must produce files."""

    def test_python_blocks_run(self):
        import tempfile
        bad, count = [], 0
        for path in md_files():
            for line, code in blocks(path, "python"):
                if not code.lstrip().startswith("# test: python"):
                    continue
                count += 1
                with tempfile.TemporaryDirectory() as tmp:
                    p = subprocess.run([sys.executable, "-c", code], cwd=tmp, capture_output=True, text=True, timeout=60)
                    if p.returncode != 0:
                        bad.append("%s:%d: %s" % (rel(path), line, p.stderr.strip()[-500:]))
                        continue
                    produced = sorted(os.listdir(tmp))
                    if not produced:
                        bad.append("%s:%d: produced no files" % (rel(path), line))
                    for fn in produced:
                        if fn.endswith(".x"):
                            text = read(os.path.join(tmp, fn))
                            for token in ("xof 0303txt 0032", "Mesh ", "MeshNormals", "MeshMaterialList", "MeshTextureCoords", "TextureFilename"):
                                if token not in text:
                                    bad.append("%s:%d: %s lacks %s" % (rel(path), line, fn, token))
                        if fn.endswith(".png"):
                            with open(os.path.join(tmp, fn), "rb") as f:
                                head = f.read(8)
                            if head != b"\x89PNG\r\n\x1a\n":
                                bad.append("%s:%d: %s is not a PNG" % (rel(path), line, fn))
        self.assertGreater(count, 0, "expected a `# test: python` block (the mesh generator)")
        self.assertEqual(bad, [], "\n".join(bad))


class TestReference(unittest.TestCase):
    def test_reference_is_generated_and_current(self):
        p = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_api_reference.py"), "--check"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)

    def test_reference_size_budget(self):
        ref = os.path.join(SKILL, "reference")
        total = sum(os.path.getsize(os.path.join(ref, f)) for f in os.listdir(ref) if f.endswith(".md"))
        self.assertLess(total, REFERENCE_BUDGET)
        self.assertTrue(os.path.exists(os.path.join(ref, "README.md")))


class TestSimSnippets(unittest.TestCase):
    """```lua blocks starting with `-- sim: client` run inside the offline single-player harness (tests/sim) with the
    whole mod loaded: the snippet must execute, survive a few ticks and a render pass, and leave no broken hook."""

    @classmethod
    def setUpClass(cls):
        from lupa import lua51
        sim = os.path.join(ROOT, "tests", "sim")
        lua_root = os.path.join(MOD, "42", "media", "lua")
        cls.rt = lua51.LuaRuntime(unpack_returned_tuples=True)
        cls.rt.execute(open(os.path.join(sim, "sim_prelude.lua")).read())
        cls.rt.execute("next = nil; io = nil; bit = nil; string.dump = nil; load = nil; dofile = nil; loadfile = nil")
        for f in ["shared/ZomboidMCP/Json.lua", "server/ZomboidMCP/Bridge.lua", "server/ZomboidMCP/Api/Visuals.lua",
                  "client/ZomboidMCP/ClientBase64.lua", "client/ZomboidMCP/ClientTextures.lua",
                  "client/ZomboidMCP/ClientSprites.lua", "client/ZomboidMCP/ClientFalling.lua",
                  "client/ZomboidMCP/ClientOverlay.lua", "client/ZomboidMCP/ClientInput.lua",
                  "client/ZomboidMCP/ClientModels.lua", "client/ZomboidMCP/Client.lua"]:
            src = open(os.path.join(lua_root, f)).read()
            cls.rt.eval("function(s, n) local f, e = loadstring(s, n) if not f then error(e) end return f end")(src, "=" + f)()
        cls.rt.execute("SIM.fire('OnGameStart')")
        cls.run_snippet = cls.rt.eval("""function(src, name)
            local f, e = loadstring(src, name)
            if not f then return false, "compile: " .. tostring(e) end
            local ok, err = pcall(f)
            if not ok then return false, tostring(err) end
            SIM.out = {}
            for i = 1, 3 do SIM.tick(1) end
            SIM.render()
            SIM.fire('OnKeyStartPressed', 57)
            ZMCPClient.overlay:onMouseDown(100, 100)
            SIM.tick(1); SIM.render()
            local removed = {}
            for _, line in ipairs(SIM.out) do if line:find("removed:") then removed[#removed + 1] = line end end
            ZMCPClient.offAll()
            ZMCPClient.draw.clear(); ZMCPClient.sprites.remove()
            if #removed > 0 then return false, table.concat(removed, "; ") end
            return true, ""
        end""")

    def test_sim_snippets_run(self):
        bad, count = [], 0
        for path in md_files():
            for line, code in blocks(path, "lua"):
                if not code.lstrip().startswith("-- sim: client"):
                    continue
                count += 1
                ok, err = self.run_snippet(code, "=%s:%d" % (rel(path), line))
                if not ok:
                    bad.append("%s:%d: %s" % (rel(path), line, err))
        self.assertGreater(count, 3, "expected several `-- sim: client` snippets")
        self.assertEqual(bad, [], "\n".join(bad))


if __name__ == "__main__":
    unittest.main()
