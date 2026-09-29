# Zomboid MCP developer targets. See README.md, docs/API_INDEX.md.
PZ_DIR ?= $(HOME)/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid
PYTHON ?= python3

.PHONY: test test-lua test-sim test-mcp luacheck docs api-index verify-api-index

# Everything offline: Lua syntax, Json unit tests, the single-player simulation, the MCP server against a fake game,
# and the catalogue/docs consistency checks. Needs `pip install lupa` (or a lua5.1/luajit binary for the Json tests).
test: luacheck test-lua test-sim test-mcp

luacheck:
	$(PYTHON) tests/luacheck.py

test-lua:
	$(PYTHON) tests/run_lua_tests.py

test-sim:
	$(PYTHON) tests/sim/test_sim.py

test-mcp:
	$(PYTHON) -m unittest discover -s tests/mcp -q

# Regenerate docs/TOOLS.md from the MCP catalogue (mcp/zmcp_catalog.py).
docs:
	$(PYTHON) tools/gen_tools_md.py

# Rebuild mcp/api_index.json.gz + mcp/lua_examples.json.gz from the local game install.
api-index:
	$(PYTHON) tools/build_api_index.py --pz-dir "$(PZ_DIR)"

# Check that the ZOM-3 acceptance symbols resolve in the built index.
verify-api-index:
	$(PYTHON) tools/build_api_index.py --verify
