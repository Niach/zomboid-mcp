# Constraints: the rules and limits in one page

What every script and tool call has to respect on a live Project Zomboid 42.21 server. Details and the evidence:
`docs/ENGINE_NOTES.md`, `docs/PROTOCOL.md`, the skill (`mod/Contents/mods/ZomboidMCP/skill/`).

## Authority

| server-authoritative (change on the server, synced, saved) | client-authoritative (change on that player's client) |
|---|---|
| zombies, animals, items (inventory and ground), tile objects, vehicles, weather, time, XP, traits, god mode, server sounds | player position, body damage and infection, appearance, stats and moodles, everything drawn on screen (overlays, sprites, textures, 3D layers) |

A server-side heal or cure is overwritten by the client within a second. Client visuals exist only on clients with the mod.

## Execution

- Server `OnTick` ≈ 10/s while players are online. **Pause when empty:** with nobody online no Lua event fires at all;
  the MCP polls through the console (`reloadlua`) when it can, otherwise it reports the server as paused.
  `OnPlayerUpdate` / `OnZombieUpdate` never fire on the dedicated server.
- A `run_lua_server` chunk blocks the whole server: keep it under ~100 ms, never wait in a loop; use
  `ZMCP.tickHooks.<name>` for periodic work and `script_install` for anything that must survive a reload.
- A `run_lua_client` chunk that loops forever freezes that player's game.
- Only squares near online players are loaded; `getCell():getGridSquare` is nil elsewhere.
- Requests older than 60 s are refused (stale). One MCP per Lua dir.
- `loadstring` works; `require` of files not loaded at startup does not. Every file must be re-runnable (state in a
  global table, handlers removed before re-adding). `reloadlua <file>` re-runs an already loaded file.

## Kahlua (Lua 5.1 dialect)

No `io`, no `bit` (use arithmetic), **no `next()`** (`for _ in pairs(t) do return false end return true`),
`tostring()` needs an argument, `os.date` works, Java overloads resolve by argument count, Java lists are
`:size()` / `:get(i)` from 0, strings are Java strings (`string.byte` gives UTF-16 units), pattern sets must not start
a range with an escaped char (`[%]-~]` is not a range). Return plain tables/strings/numbers/booleans from chunks.
Two more traps with Java objects: a **void Java method returns no value at all**, so `tostring(zed:pathToLocation(x, y, z))`
or `print(obj:voidMethod())` fails with "Not enough arguments" (call it on its own line, then `tostring` something
else); and **a Java method cannot be referenced without calling it**: `obj:method and obj:method()` is a syntax error
and `obj.method` is nil for Java objects, so feature-test with `pcall(function() return obj:method() end)` instead.

- Inside a coroutine (scenes) an engine call that fires Lua events breaks the next `pcall` on that coroutine
  (`coroutine changed in pcall`, dedicated server): scenes use `try` / `engine` (docs/SCENES.md), never `pcall`
  around a world call.

## Files

- Only the Lua cache dir (`~/Zomboid/Lua`) is reachable: `getFileWriter(name, create, append)` (text),
  `getFileOutput(name)` + `writeByte` + `endFileOutput()` (binary), `getFileReader(name, create)` (throws for a
  missing file: pcall it). `fileExists` needs the absolute path. No list, delete, rename.
- `getFileWriter` refuses names ending in `.lua` / `.jsonl` and names without an extension; `.txt`, `.json`, `.log`,
  `.lua.txt` work. Parent directories are created (`media/x.png` works).
- The server heap is 3 GB with little spare: textures, snapshots and logs go to files, never into Lua tables or ModData.

## Sizes and counts

| thing | limit |
|---|---|
| server → client message | ~3 kB; 12 messages per tick (about 1 s per 30 kB of base64) |
| texture PNG | ≤ 256×256 and ≤ 100 kB recommended; hard limit 1.2 M base64 chars |
| tool string argument | > 32 kB is passed as a file automatically |
| client result value | 4000 chars per client |
| `give_item` / `spawn_item` / `spawn_zombies` / `build_structure` / `falling_items` | 100 / 200 / 100 / 500 / 200 per call |
| `world_query` radius | ≤ 80 (zombies), ≤ 40 (objects, items) |
| model files | mesh path must contain `media/` and an extension; model space is Y-up, origin at ground level |

## Visuals

- Textures are cached by path: new content needs a new file name (the mod bumps a generation per re-upload).
- World sprites are drawn always on top (no occlusion) and are not objects (no collision, no save).
- Static 3D models on world items render fine; changing their offset/rotation every tick flickers (chunk FBO cache).
- A render/tick/input hook that throws is removed after the first error; register hooks under the script name.
- `run_lua_client`, `overlay_draw`, `falling_items`, `server_message` and sprites with `ttl`/`player` are one-shot;
  textures, models, client scripts and other sprites are re-sent to late joiners.

## Etiquette on the live server

- Read-only and reversible things freely: `status`, `players_list`, `world_query`, `player_info`, `events_poll`,
  `api_search`, `lua_examples`, sprites and overlays with `ttl`, small item drops.
- Ask first: hordes, killing, teleporting or editing a character, building next to players, weather/time jumps in a
  session, restarts, `server_console` commands that stop or reconfigure the server, Workshop uploads (SteamCMD with the
  owner's account kicks their desktop Steam).
- Never touch the owner's running single-player game uninvited; one agent at a time on any live game.
- Clean up what you made (`clear_visuals`, `script_remove` after the script's own `stop()`, remove spawned objects).
- Secrets and deployment details (ssh target, container, paths) stay in `~/.config/zomboid-mcp/local.env`, never in
  the repo or in a tool call that gets logged.
