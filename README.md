# Zomboid MCP — Claude hacks the simulation

A Project Zomboid (Build 42) mod plus a bundled MCP server that gives Claude (or any MCP client) live control over a running game: query the world, spawn things, build with tiles, change weather and time, manage players, and push brand-new visuals (textures, sprites, overlays) to every connected player. Nothing needs a restart or a Workshop update.

The project is in progress. See [docs/PLAN.md](docs/PLAN.md) for the architecture and [docs/ENGINE_NOTES.md](docs/ENGINE_NOTES.md) for the verified engine facts.

## Layout
- `mod/Contents/mods/ZomboidMCP/`: the Workshop item (`42/media/lua/{shared,server,client}/ZomboidMCP`). The MCP server ships inside the mod under `mcp/` and the skill under `skill/`.
- `tools/`: the dev CLI (`pz`), Workshop upload and server deploy, and `build_api_index.py` (regenerates the engine API index with `make api-index`, see [docs/API_INDEX.md](docs/API_INDEX.md)).
- `spikes/`: experiments. `art/`: sample art.

## Install
1. Subscribe to the Workshop item and enable **Zomboid MCP** (server: add it to `WorkshopItems` / `Mods`). The MCP
   server is the `mcp/` folder inside the mod: pure Python 3.9+ standard library, nothing to `pip install`.
2. Register it with Claude Code (one line):

   ```sh
   # local single-player or hosted game: the Lua dir (~/Zomboid/Lua) is auto-detected
   claude mcp add zomboid -- python3 "<workshop>/3810456179/mods/ZomboidMCP/mcp/zomboid_mcp.py"

   # remote dedicated server over ssh, with raw console access through its docker container
   claude mcp add zomboid -- python3 zomboid_mcp.py --ssh root@host \
       --lua-dir /var/lib/docker/volumes/<volume>/_data/Lua --console-container <container>

   # or keep the deployment details in a file (ZMCP_SSH, ZMCP_LUA_DIR, ZMCP_CONTAINER)
   claude mcp add zomboid -- python3 zomboid_mcp.py --env-file ~/.config/zomboid-mcp/local.env
   ```

   A repo checkout works the same way: `mod/Contents/mods/ZomboidMCP/mcp/zomboid_mcp.py`.
3. Check the connection: `python3 zomboid_mcp.py --check [--ssh ... --lua-dir ...]` prints the game status
   (`bridge: live | paused | stale | not_running` with a hint) and exits 0 when the bridge is live.

Other MCP clients: `python3 zomboid_mcp.py --http 8765 ...` serves streamable HTTP on `http://127.0.0.1:8765/mcp`
(POST JSON-RPC, localhost only). `--list-tools` prints the tool catalogue, `--help` lists every option.

### How it works
- `zomboid_mcp.py` speaks MCP (JSON-RPC 2.0, spec 2025-06-18) over stdio or localhost HTTP and reaches the game
  through the file protocol in [docs/PROTOCOL.md](docs/PROTOCOL.md): one `zmcp_req_<n>.json` per call in the game's
  `Zomboid/Lua` directory, answered by `Bridge.lua` on the next server tick. Remote servers are reached over a persistent
  ssh ControlMaster (one ssh exchange per call).
- Scripting-first: `run_lua_server` and `run_lua_client` (all clients or one player) plus persistent script modules
  (`script_install` / `script_list` / `script_remove`) are the primary tools; a small curated set (status, players,
  texture/model upload, spawn item/vehicle/zombies, world sprite, static/moving 3D objects, falling items, weather/time,
  server_console) covers the most common operations. The catalogue (`mcp/zmcp_catalog.py`) documents every tool with
  where the code runs, its authority (server vs client), who sees the effect, return/error handling and limits, and
  points at the "zomboid engine handbook" skill. Tools the running game registers beyond the catalogue are exposed as
  passthrough tools.
- `api_search` / `lua_examples` answer from `mcp/api_index.json.gz` and `mcp/lua_examples.json.gz`
  ([docs/API_INDEX.md](docs/API_INDEX.md)); `events_poll` tails `zmcp_events.jsonl`; `wait_for` blocks until a player
  is online; `server_console` writes to the dedicated server's console FIFO and returns the new console output.
- Arguments longer than 32 kB (base64 PNGs, long Lua) are written as `zmcp_blob_<n>_<key>.txt` and the argument is
  passed as `<key>_file` instead, so request files stay small.
- Tests: `python3 -m unittest discover -s tests/mcp` runs against a fake game (`tests/mcp/fake_game.py`);
  `python3 tests/mcp/live_smoke.py` runs read-only calls against the live server from `~/.config/zomboid-mcp/local.env`.
