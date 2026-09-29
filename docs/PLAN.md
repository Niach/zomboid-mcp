# DIRECTION UPDATE (2026-09-30, owner): scripting-first
- **Core capability:** Claude writes Lua and runs it live, through `run_lua` MCP tools:
  - `run_lua_server`, run in the server/host Lua state
  - `run_lua_client`, run on all clients or one player's client
  - persistent script modules (install/list/remove, auto-reload on join/restart)
- **Knowledge:** a large Claude skill, the "Zomboid engine handbook":
  - the full map of Lua-reachable engine functions (generated from the ZOM-3 index into categorized markdown references)
  - guides for 2D overlays and screen apps, runtime textures, 3D static models, 3D moving entities, world/tiles, items, zombies (incl. passive puppet actors), vehicles, weather/time, players, and scenes (coroutines)
  - tested code snippets
  - every gotcha from `docs/ENGINE_NOTES.md`
- **Curated MCP tools:** only the best, most-used operations stay as tools (status/players, texture/model upload, spawn item/vehicle/zombies, world sprite, 3D object static/moving, falling items, weather/time, `server_console`). Everything else is done by scripting.
- **Both static and moving 3D objects are first-class:**
  - Static: a runtime `ModelScript` on a world item (verified, no flicker).
  - Moving: needs a dynamic carrier (ZOM-11), because animated world items flicker due to chunk FBO caching.
- **Dropped:** Guardian and Reborn (ZOM-5 cancelled), and all easter eggs.

# Zomboid MCP — "Claude hacks the simulation"

## Context
- You want one proper mod that exposes as much of Project Zomboid's engine as possible to Claude through MCP, so anything you come up with (giant snail, bananas from the sky, …) can be made to happen live, with good docs and a skill.
- **Removed:** Hyper Sniper, Cool Jesus and lightning. No easter eggs.
- **Kept as MCP tools** (off unless used): the Guardian features (heal, cure, clear, god mode, auto-rescue) and Reborn (snapshot/restore).
- **Must be easy to install:** the MCP server ships **inside the mod**, is pure Python stdlib (no pip), and needs one `claude mcp add` line.
- **Workshop:** reuse item **3810456179**, renamed "Zomboid MCP", set to **Public**. Unlisted via SteamCMD turned into Private, which blocked joins.
- **Server state right now:** joins hang at `GettingServerInfo`. The item is public again (API confirms), and the server needs one restart to re-read it.

What's already proven on our 42.21 server, and gets reused:
- File bridge through `Zomboid/Lua/` (`getFileWriter`/`getFileReader`)
- Live `loadstring` eval
- Server `OnTick` (≈10 Hz while players are online; paused when empty) and `EveryOneMinute`
- Hot reload via `reloadlua` and file-run
- Client `exec` push with chunking and late-join resend (`hello`)
- Server-authoritative calls: `Kill`, `AddItem`+`sendAddItemToContainer`, `addXpNoMultiplier`, traits, `setGodMod`+`sendPlayerExtraInfo`, `vehicle:repair()`, `transmitServerTriggerLightning`, `playServerSound`
- **Client-authoritative, only unreliable server-side fixes:** infection and body state (the vanilla `syncBodyPart` path only)
- **New:** `getFileOutput()` gives a binary `DataOutputStream` in Lua, and `Texture`, `getTexture` and `getTextureFromSaveDir` are exposed. Runtime PNG → texture on clients looks feasible but is unverified (spike, step 3).

## Repo: `~/Projects/zomboid-mcp` (git)
```
mod/Contents/mods/ZomboidMCP/        Workshop item 3810456179 (upload root = mod/Contents)
  mod.info, 42/mod.info, poster/icon
  42/media/lua/shared/ZomboidMCP/Json.lua          small JSON encode/decode
  42/media/lua/server/ZomboidMCP/Bridge.lua        inbox/outbox request-response, dispatch, hot reload
  42/media/lua/server/ZomboidMCP/Api/*.lua         tool implementations (world, players, items, zombies, vehicles, weather, objects, fx, guardian, reborn)
  42/media/lua/client/ZomboidMCP/Client.lua        exec, overlay/render hooks, textures, world sprites, falling items, input events
  mcp/zomboid_mcp.py                               stdlib MCP server (stdio + optional --http localhost)
  mcp/api_index.json.gz                            searchable engine API index (generated)
  skill/SKILL.md                                   Claude Code skill: recipes, constraints, gotchas
docs/README.md, docs/TOOLS.md, docs/CONSTRAINTS.md
tools/build_api_index.py   (javap over projectzomboid.jar Lua-exposed classes + vanilla Lua function index)
tools/upload.sh            (SteamCMD isolated HOME $ZMCP_STEAMCMD_HOME, public)
tools/deploy_server.sh     (push server Lua to /opt/zomboid-lua for hot reload during development)
```
Server-side Lua is **in the mod**, so single-player and self-hosted games get it too. On our server it's additionally bind-mounted from `/opt/zomboid-lua` for hot reload during development. The existing mount is renamed to `ZomboidMCP`, and the old `vapps` files are removed.

## Bridge protocol
- **Requests:** MCP → `Zomboid/Lua/zmcp_in/<id>.json`, one file per request, so nothing gets overwritten.
  - The server polls the inbox **every tick** and executes: tool name + args, or raw `eval`.
  - The result goes to `zmcp_out/<id>.json`.
  - Kahlua can't list a directory, so an `index.txt` append-log carries the ids.
- **Events:** the server appends to `zmcp_events.jsonl` (deaths, joins, chat-like notes, tool errors). The MCP exposes them as `events_poll`.
- **Heartbeat:** `zmcp_status.json`, written every 2 s: players, time, weather, zombie counts, version.
- **Transports in `zomboid_mcp.py`:**
  - `local` (default: `~/Zomboid/Lua`, for single-player or host)
  - `ssh` (`ZOMBOID_SSH=$ZMCP_SSH`, `ZOMBOID_LUA_DIR=<volume>/Lua`), using a persistent ControlMaster
- **Timeout handling:** if the server is paused/empty, return a clear "server paused (no players online)" error.

## MCP tools (curated plus escape hatches)
- **Discover:**
  - `status`
  - `players_list`
  - `player_info`
  - `world_query` (square/objects/zombies/vehicles/items in radius)
  - `api_search` (engine API index)
  - `lua_examples` (grep vanilla Lua)
- **Players:**
  - `teleport`
  - `heal` / `cure` / `god_mode`
  - `set_traits`, `set_skills`, `set_appearance`
  - `give_item`
  - `snapshot` / `restore` (Reborn)
- **World:**
  - `spawn_item` (ground/inventory)
  - `spawn_vehicle`, `vehicle_fix` (repair/refuel)
  - `spawn_zombies`, `kill_zombies_area`
  - `place_object` (any vanilla tile sprite), `remove_object`
  - `set_weather` / `set_time`
  - `sound`, `lightning`, `server_message`
- **Visuals (client push, everyone with the mod):**
  - `client_exec` (Lua on all or one client), `overlay_draw` (shapes/text, screen- or world-anchored)
  - `texture_upload` (PNG base64 → all clients → texture id)
  - `world_sprite` (texture at world x,y,z with scale and motion path)
  - `falling_items` (visual fall + real items on landing)
  - `clear_visuals`
- **Power:**
  - `lua_eval_server` / `lua_eval_client`, `module_install` (persistent hot-loaded Lua modules), `module_list` / `module_remove`
- **Auto:**
  - `guardian_config` (auto-rescue thresholds, on/off per player)
- **Descriptions:** every tool description states authority (server vs client), who sees the result, and limits.

## Steps
1. **Fix joins now:** save, then restart the service. Verify `workshop_log.txt` has no "private" or "Access Denied" and that you can join. Re-arm the watchers.
2. **Repo scaffold:** move the working pieces over:
   - Guardian, Reborn and Push become `Api/guardian.lua`, `Api/reborn.lua` and the client exec
   - `pz` → `tools/`
   - Delete CoolJesus, `halo.lua` and the Dota assets
3. **Texture spike (decides the art pipeline):** a client receives base64 PNG chunks, decodes them, writes them via `getFileOutput`, then loads with `Texture.new(path)` / `getTextureFromSaveDir` / `getTexture`.
   - Test it live through the current `exec` push, before building the tools.
   - Fallback if it fails: pixel sprites via `drawRect`, plus compositions of vanilla textures (`getItemTex`, tile textures).
4. **Build:**
   - the bridge and Json.lua
   - the API modules
   - the client renderer: world-anchored sprites that scale with `getCore():getZoom`, falling items, overlays
   - `zomboid_mcp.py`: MCP 2025-06-18 JSON-RPC over stdio, plus `--http` on 127.0.0.1 using `http.server`
   - `api_index` generator
5. **Docs and skill:**
   - SKILL.md: when to use which tool, recipes (bananas, giant snail, build a house from tiles, horde event), constraints, B42 gotchas we learned
   - README: install is subscribe + `claude mcp add zomboid -- python3 …/mcp/zomboid_mcp.py [--ssh …]`
6. **Deploy:**
   - Upload public to 3810456179 with title "Zomboid MCP"
   - Change the server `MOD_IDS` `\vappsTweaks` → `\ZomboidMCP`
   - Bind mount `/opt/zomboid-lua/ZomboidMCP` → `media/lua/server/ZomboidMCP` (dev hot reload)
   - Restart once
   - `claude mcp add` locally
7. **Memory:** update the zomboid memory with the Unlisted pitfall, the MCP location and how it's installed.

## Verification (acceptance demos, done live with you)
- `status` and `players_list` return you.
- `api_search "addLamppost"` finds the signature.
- **Bananas:** `falling_items` Base.Banana ×20 around you. Everyone sees them fall, and they can be picked up (the server spawns the real items).
- **Giant snail:** Claude generates a snail PNG, then `texture_upload` + `world_sprite` next to you, scaled to about 3 tiles, slowly crawling. A friend sees it too. If the texture spike failed, it's a pixel sprite instead.
- `place_object` builds a small wall ring from vanilla tiles, and `remove_object` clears it.
- `module_install` hot-reloads a change without a restart. The server keeps running, and joins stay instant after a restart.
