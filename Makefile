# Zomboid MCP developer targets. See README.md, docs/API_INDEX.md.
PZ_DIR ?= $(HOME)/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid
PYTHON ?= python3

.PHONY: test test-lua test-sim test-mcp test-skill luacheck docs reference api-index verify-api-index

# Everything offline: Lua syntax, Json unit tests, the single-player simulation, the MCP server against a fake game,
# and the catalogue/docs consistency checks. Needs `pip install lupa` (or a lua5.1/luajit binary for the Json tests).
test: luacheck test-lua test-sim test-mcp test-skill

luacheck:
	$(PYTHON) tests/luacheck.py

test-lua:
	$(PYTHON) tests/run_lua_tests.py

test-sim:
	$(PYTHON) tests/sim/test_sim.py
	$(PYTHON) tests/sim/test_scenes.py

test-mcp:
	$(PYTHON) -m unittest discover -s tests/mcp -q

# The skill: frontmatter, links, every ```lua block compiles under Lua 5.1, tool calls match the catalogue,
# the generated API reference is current (tools/gen_api_reference.py --check).
test-skill:
	$(PYTHON) -m unittest discover -s tests/skill -q

# Regenerate docs/TOOLS.md from the MCP catalogue (mcp/zmcp_catalog.py).
docs:
	$(PYTHON) tools/gen_tools_md.py

# Regenerate the skill's categorized API reference (skill/reference/*.md) from mcp/api_index.json.gz.
reference:
	$(PYTHON) tools/gen_api_reference.py

# Rebuild mcp/api_index.json.gz + mcp/lua_examples.json.gz from the local game install.
api-index:
	$(PYTHON) tools/build_api_index.py --pz-dir "$(PZ_DIR)"

# Check that the ZOM-3 acceptance symbols resolve in the built index.
verify-api-index:
	$(PYTHON) tools/build_api_index.py --verify
