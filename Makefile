# Zomboid MCP developer targets. See docs/API_INDEX.md.
PZ_DIR ?= $(HOME)/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid
PYTHON ?= python3

.PHONY: api-index verify-api-index

# Rebuild mcp/api_index.json.gz + mcp/lua_examples.json.gz from the local game install.
api-index:
	$(PYTHON) tools/build_api_index.py --pz-dir "$(PZ_DIR)"

# Check that the ZOM-3 acceptance symbols resolve in the built index.
verify-api-index:
	$(PYTHON) tools/build_api_index.py --verify
