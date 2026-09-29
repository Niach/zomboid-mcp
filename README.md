# Zomboid MCP — Claude hacks the simulation

A Project Zomboid (Build 42) mod plus a bundled MCP server that gives Claude (or any MCP client) live control over a
running game: script the engine from the outside, spawn things, build with tiles, change weather and time, move players,
and push brand-new visuals (textures, world sprites, 3D models, falling items, overlays, screen apps) to every connected
player. Nothing needs a restart or a Workshop update.

It is **scripting-first**: `run_lua_server` and `run_lua_client` run Lua you write in the server and client Lua states,
`script_install` makes it persistent, and the "zomboid engine handbook" skill plus `api_search` / `lua_examples` tell you
what the engine can do. A curated set of tools covers the common operations with validated arguments.

- [docs/TOOLS.md](docs/TOOLS.md): every MCP tool with its arguments (generated from the catalogue).
- [docs/PROTOCOL.md](docs/PROTOCOL.md): how the MCP talks to the server (files in `Zomboid/Lua`) and how the server
  talks to the client mod (`sendServerCommand`).
- [docs/ENGINE_NOTES.md](docs/ENGINE_NOTES.md): verified engine facts, authority rules and pitfalls for B42.
- [docs/recipes/](docs/recipes/README.md): the raw Lua behind each tool, and for things that are scripts only.
- [docs/API_INDEX.md](docs/API_INDEX.md): the engine API index behind `api_search` / `lua_examples`.
- [docs/PLAN.md](docs/PLAN.md): direction, architecture and status.

## Install

1. Subscribe to the Workshop item and enable **Zomboid MCP** (server: add it to `WorkshopItems` / `Mods`). The MCP
   server is the `mcp/` folder inside the mod: pure Python 3.9+ standard library, nothing to `pip install`.
2. Register it with Claude Code (one line):

   ```sh
   # local single-player or hosted game: the Lua dir (~/Zomboid/Lua) is auto-detected
   claude mcp add zomboid -- python3 "<workshop>/3810456179/mods/ZomboidMCP/mcp/zomboid_mcp.py"

   # remote dedicated server over ssh, with console access through its docker container
   claude mcp add zomboid -- python3 zomboid_mcp.py --ssh root@host \
       --lua-dir /var/lib/docker/volumes/<volume>/_data/Lua --console-container <container>

   # or keep the deployment details in a file (ZMCP_SSH, ZMCP_LUA_DIR, ZMCP_CONTAINER, ZMCP_POLL_FILE)
   claude mcp add zomboid -- python3 zomboid_mcp.py --env-file ~/.config/zomboid-mcp/local.env
   ```

   A repo checkout works the same way: `mod/Contents/mods/ZomboidMCP/mcp/zomboid_mcp.py`.
3. Install the skill: `mcp/install.sh` (see `skill/SKILL.md`; the skill is the knowledge Claude needs to script the
   engine well).
4. Check the connection: `python3 zomboid_mcp.py --check [--ssh ... --lua-dir ...]` prints the game status
   (`bridge: live | paused | stale | not_running` with a hint) and exits 0 when the bridge is live.

Other MCP clients: `python3 zomboid_mcp.py --http 8765 ...` serves streamable HTTP on `http://127.0.0.1:8765/mcp`
(POST JSON-RPC, localhost only). `--list-tools` prints the tool catalogue, `--help` lists every option.

## How it works

- **Bridge.** `zomboid_mcp.py` speaks MCP (JSON-RPC 2.0, spec 2025-06-18) over stdio or localhost HTTP and reaches
  the game through files in the game's `Zomboid/Lua` directory: one `zmcp_req_<n>.json` per call, answered by
  `Bridge.lua` on the next server tick, plus a heartbeat and an event log. Remote servers are reached over a persistent
  ssh ControlMaster (one ssh exchange per call). A dedicated server that pauses when empty is woken through its console
  (`reloadlua`) when the MCP has console access.
- **Authority.** The server owns zombies, items, world objects, vehicles, weather, time, XP and traits: server code takes
  effect for everyone at once. A player's position, body state, appearance and everything drawn on screen belong to that
  player's client, so the mod ships a client runtime that receives code, textures, 3D models, sprites, overlays and
  input hooks from the server (`docs/PROTOCOL.md` part 2). Late joiners get everything again.
- **Catalogue.** `mcp/zmcp_catalog.py` documents every tool with where the code runs, its authority, who sees the effect,
  return/error handling and limits; `docs/TOOLS.md` is generated from it and `tests/mcp/test_catalog.py` checks it
  against the Lua. Tools that scripts register at runtime (`ZMCP.tool`) are exposed as passthrough tools.
- **Knowledge.** `api_search` / `lua_examples` answer from `mcp/api_index.json.gz` and `mcp/lua_examples.json.gz`
  (rebuilt from a game install with `make api-index`); the skill under `skill/` is the handbook.

## Layout

- `mod/Contents/mods/ZomboidMCP/`: the Workshop item. `42/media/lua/shared|server|client/ZomboidMCP/` is the mod
  (`Bridge.lua`, `Api/*.lua`, `Client*.lua`, `Json.lua`), `mcp/` the MCP server and the API index, `skill/` the skill.
- `tools/`: `pz` (dev CLI for the live server), `zmcp_client.py` (reference bridge client), `deploy_server.sh`,
  `build_api_index.py`, `gen_tools_md.py`, `gen_tilesheets.sh`, `upload.sh` (Workshop).
- `tests/`: `make test` runs everything offline: Lua syntax (`luacheck.py`), `json_test.lua` under Lua 5.1,
  `sim/test_sim.py` (the whole mod under a standalone Lua 5.1 with mocked engine globals), `mcp/` (the MCP server
  against a fake game, catalogue and docs consistency). `tests/live/` are read-only smoke tests against a real server
  (`set -a; . ~/.config/zomboid-mcp/local.env; set +a; python3 tests/live/bridge_smoke.py`).
- `dev/`: `ZMCPDev`, a local-only exec-watcher mod for single-player testing, and `bundle_sp.sh` which feeds it the
  whole mod. `art/`: sample art and a verified `.x` mesh. `spikes/`: the experiments that established the pipeline.

Deployment specifics (ssh target, container, paths) are never in the repo: see `docs/local.env.example`.
