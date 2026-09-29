# Zomboid MCP protocol

Part 1: MCP ⇄ server (files in the Lua cache dir). Part 2: server ⇄ client mod (`sendServerCommand`).

# Part 1: MCP ⇄ server bridge

The MCP process and the game talk through plain files in the game's **Lua cache dir**
(`~/Zomboid/Lua/` for a local game; on our server `$ZMCP_LUA_DIR` on the host, which is
`/home/steam/Zomboid/Lua` inside the container). It is the only directory Kahlua can read and write
(`getFileReader` / `getFileWriter`). Kahlua cannot list a directory, delete a file, or rename one, so the
protocol is designed around numbered files and a heartbeat.

Server side: `mod/Contents/mods/ZomboidMCP/42/media/lua/server/ZomboidMCP/Bridge.lua`.
Reference client (stdlib Python, also used by the tests): `tools/zmcp_client.py`.

## Files

| File | Written by | Content |
|---|---|---|
| `zmcp_req_<n>.json` | MCP | one request, `{"n": n, "t": unixSeconds, "tool": "name", "args": {...}}` |
| `zmcp_res_<n>.json` | server | one response, `{"n": n, "ok": true, "result": ..., "ms": 3, "t": ...}` or `{"n": n, "ok": false, "error": "...", "ms": 0, "t": ...}` |
| `zmcp_status.json` | server | heartbeat, rewritten every 2 s and immediately after each processed request |
| `zmcp_events.log` | server | append-only event log, one JSON object per line: `{"t", "kind", "data"}` |
| `zmcp_script_<name>.lua.txt` | server | persistent server scripts written by `script_install {name, code}` |
| `zmcp_cscript_<name>.lua.txt`, `zmcp_tex_<id>.b64`, `zmcp_model_<id>.*.b64` | server | client scripts and base64 assets kept for late joiners (Api/Visuals.lua) |
| `zmcp_blob_<n>_<key>.txt` | MCP | a string argument above 32 kB, passed as `<key>_file` (see "Large arguments") |
| `zmcp_src_*.lua`, `zmcp_boot.lua`, `zmcp_run.lua` | dev tools | scratch files used by `tools/pz load` / `tools/pz run` |

`<n>` is a positive integer without padding. All JSON the MCP writes must be **ASCII only**
(`json.dumps(..., ensure_ascii=True)`, the Python default): the JVM reads the file with its default charset.
The server's JSON output is ASCII too (non-ASCII becomes `\uXXXX`).

File names the server can write are restricted: `getFileWriter` (verified on 42.21) refuses names ending in
`.lua` or `.jsonl` and names without an extension, and accepts `.txt`, `.json`, `.log`, `.lua.txt`.
`getFileReader` reads any name, so the MCP may upload `.lua` files freely. The server cannot list, delete or
rename files; `fileExists(absolutePath)` works (relative names return false).

## Request numbering

- The server keeps `nextReq`, the number of the next request it will execute. It is persisted in global
  ModData (`ModData.getOrCreate("ZomboidMCP").nextReq`, saved with the world about once a minute) and
  published in `zmcp_status.json`.
- On every tick the server tries to read `zmcp_req_<nextReq>.json`. If it exists, `nextReq` is advanced
  and persisted **first**, then the request runs and the response is written (at-most-once: a request that
  kills the Lua state is never retried). Up to 20 requests are processed per tick, strictly in order.
  Everything runs on the game thread (or on the console thread while paused, when nothing else runs), so a
  tool may touch the world freely.
- The MCP picks `n` like this:
  1. **Resync** (at startup, and after any timeout): read `zmcp_status.json`, list the existing
     `zmcp_req_*.json` files, and set `n = max(status.nextReq, highest existing request + 1)` counting only
     request files inside the probe window `[nextReq, nextReq + 10)`. Delete every other leftover
     `zmcp_req_*` / `zmcp_res_*` file: below `nextReq` it was consumed, beyond the window the server would
     never look at it.
  2. Use `n`, `n + 1`, ... for the following requests without reading status again.
- **Gaps.** If `zmcp_req_<nextReq>.json` never shows up (the MCP crashed between choosing `n` and writing,
  or withdrew a timed-out request), the server probes `nextReq + 1 ... nextReq + 10` every 0.25 s and jumps
  to the first request it finds, logging a `gap` event. Requests further ahead than 10 are never seen:
  the MCP must not run more than 10 numbers ahead of `status.nextReq`.
- **Restarts.** ModData is saved about once a minute, so after a crash the server can come back with a
  lower `nextReq` than the MCP's counter, and after a clean restart with a value the MCP has already used.
  The MCP detects both from the response timeout plus a fresh status (`status.bootId` changes on every
  server start, never on a hot reload) and resyncs. A request the server finds that is older than 60 s
  (`t` field) is answered with `ok=false, error="stale request ..."` instead of being executed, so a
  request written before a restart or a long pause can never fire late.
- The MCP must be the only writer of request files for a Lua dir. Two clients on the same dir collide.

## Writing a request and reading the response

1. Write the request to `zmcp_req_<n>.json.tmp`, then **rename** it to `zmcp_req_<n>.json`. The server may
   read the file the moment it exists; the rename makes the write atomic.
2. Poll for `zmcp_res_<n>.json`. The server writes the JSON followed by a single `\n`; wait until the file
   ends with a newline before parsing it (the write is not atomic on the server side).
3. Delete both files. The server never deletes anything.
4. Timeout: default 10 s (longer for tools that do a lot of work). On timeout delete the request file
   (withdraw it), then resync and retry once at the fresh number if that number differs (the server came
   back with another counter). If it still fails, report, using the status:
   - heartbeat older than 5 s: the bridge is not loaded (server down, Bridge.lua not loaded) or the server
     is paused and no poll command is configured (see "Paused server");
   - `status.nextReq > n`: the response was lost (should not happen);
   - otherwise the tool is still running (a long `run_lua_server`).

The reference implementation does steps 1 to 3 in a single `ssh` exec for the remote transport
(write, trigger a poll if needed, wait on the host, cat, delete): one ssh exchange plus one tick.
Measured on the live server (ssh from the dev PC, server paused, so every request also pays for a
`docker exec` poll): ping round trip 280 to 390 ms, average about 310 ms.

## Status file

```json
{
  "version": "0.2.0",
  "bootId": "1790722060-482913",   // new on every server start, kept across hot reloads
  "t": 1790722100.5,               // unix time of this write
  "uptime": 40,                    // seconds since the bridge first loaded in this process
  "nextReq": 58,
  "lastReq": {"n": 57, "tool": "ping", "ok": true, "ms": 1, "t": 1790722099.9},
  "paused": false,                 // true when the game loop is paused and OnTickEvenPaused is serving requests
  "tps": 10,                       // OnTick calls in the last second (0 while paused)
  "server": true,                  // isServer(); false for a single-player host
  "players": [{"user": "niach", "name": "Cool Jesus", "x": 6400, "y": 5498, "z": 0, "dead": false, "health": 100}],
  "time": {"hour": 13.5, "day": 12, "month": 7, "year": 1993},
  "tools": ["run_lua_server", "script_install", "..."],
  "scripts": ["snail"],
  "stats": {"requests": 57, "errors": 2}
}
```

"Bridge alive" means `now - status.t < 5` while players are online. While the server is paused the heartbeat
is only written when something polls the bridge (see below), so a stale heartbeat alone does not mean the
bridge is gone.

## Paused server

Verified live on 42.21 with `PauseEmpty=true` and nobody online: the dedicated server pauses its main loop
and **no Lua event fires at all**. Not `OnTick`, not `EveryOneMinute`, and not `OnTickEvenPaused` (the event
exists and can be registered, but a bridge loaded while paused never received a single call). So a paused
server cannot answer on its own.

What does work while paused: **server console commands**, including `reloadlua <file>`, which re-runs a
server Lua file that was loaded at startup (matched by path suffix). The bridge uses that as its paused
path:

- `ZomboidMCP/ZMCPPoll.lua` (in the mod, and in the dev mount) is a one-liner: `if ZMCP and ZMCP.poll then ZMCP.poll() end`.
  `ZMCP.poll()` runs one pass of the request loop and writes the heartbeat with `paused=true`. It returns
  immediately when `OnTick` was seen within the last second, so it is harmless while players are online.
- The MCP, whenever the heartbeat is older than 3 s **or** the last heartbeat says `paused`, writes the
  request and then triggers the poll command on the host, for our server
  `echo 'reloadlua ZomboidMCP/ZMCPPoll.lua' | docker exec -i $ZMCP_CONTAINER sh -c 'cat > /tmp/pz-console'`
  (`ZMCP_POLL_CMD`, or built from `ZMCP_CONTAINER` and `ZMCP_POLL_FILE` in `tools/zmcp_client.py`). One poll
  answers everything pending. The bridge also runs a pass at the end of every (re)load, so `reloadlua` of
  Bridge.lua itself, or the dev bootstrap, polls too.
- Until the ZomboidMCP bind mount exists, `ZMCPPoll.lua` is not loaded on the server; the poll target is the
  bootstrapped old Guardian file instead: `ZMCP_POLL_FILE=VappsGuardian.lua` (see "Dev workflow"). Its
  bootstrap block calls `ZMCP.poll()` when the bridge is already loaded.
- Without a poll command (no docker/console access, e.g. a plain Workshop user) the MCP reports a clear
  error after the timeout: the server is paused because nobody is online, join the server or configure
  polling.
- `OnTickEvenPaused` stays registered in Bridge.lua for hosts where it does fire (single player, other
  builds); it yields to `OnTick` and is throttled to 5 Hz.

Consequences for tools while paused: the world does not simulate (zombies do not move, time stands still),
world edits are applied but only saved on the next autosave, and objects/squares outside any player's
loaded area are not available. Requests are executed on the console thread then; that is safe only because
the game thread sleeps while paused, and the bridge never uses the poll path while `OnTick` is alive.

Status shows it: `paused=true`, `tps=0`.

## Events

`zmcp_events.log` grows forever (the server cannot truncate it; the MCP may). Each line is
`{"t": unixSeconds, "kind": "bridge_loaded" | "gap" | "script_install" | "script_remove" | "script_error" | "client_hello" | "client_exec_result" | "client_texture" | "client_model" | <tool name> | <script-defined>, "data": {...}}`.
Read it with `tail -c +<offset>` and remember the offset.

## Core tools (registered by Bridge.lua)

| tool | args | result |
|---|---|---|
| `ping` | | `{pong, version, bootId, paused, players}` |
| `status` | | the status document, written fresh (Api/World.lua adds weather and loaded counts) |
| `tools_list` | | `[{name, desc}]` |
| `run_lua_server` | `{code}` | the chunk's return value (an array when it returns several) |
| `run_file` | `{file}` | runs a Lua file from the Lua dir once; not remembered (dev tooling) |
| `script_install` | `{name, code, side?}` | `side` = `server` (default): writes `zmcp_script_<name>.lua.txt`, runs it, records it in ModData so it runs again on every bridge load and server start. `side` = `client`: Api/Visuals.lua stores it and pushes it to every client now and on join. Other sides plug into `ZMCP.scriptSides` |
| `script_list` | | `{server = [{name, file, installed}], client = [...]}` |
| `script_remove` | `{name, side?}` | forgets the script (the file stays; handlers a server script registered stay until the next restart unless the script removes them itself; clients drop the hooks of a client script at once) |

Errors are returned as `{"ok": false, "error": "<lua error message>"}`; a Lua error inside a tool never
breaks the loop.

## Large arguments

Any string argument longer than 32 kB (base64 PNGs, long Lua sources) is written by the MCP to
`zmcp_blob_<n>_<key>.txt` in the Lua dir and the argument is replaced by `<key>_file` = that file name
(`png_base64` becomes `png_base64_file`). Tools read such arguments with `ZMCP.argText(args, "png_base64")`,
which returns the inline value or the file's content. The MCP deletes the blob together with the request and
response files after the response, unless the tool's result object contains `"keep_files": true`; tools that
need the data later (textures, models for late joiners) copy it into their own file.

## Writing tools and scripts (Lua side)

Everything goes through the `ZMCP` table (see the header of `Bridge.lua`):

```lua
ZMCP.tool("hello", "Say hi. args: {name}", function(a)
    return { hi = tostring(a.name), players = ZMCP.playerNames() }
end)
ZMCP.tickHooks.hello = function(t) --[[ runs every processed tick, t = unix seconds ]] end
ZMCP.event("hello", { who = "world" })
```

Rules for every server file (Bridge.lua, Api/*.lua, scripts):
- **Re-runnable.** Keep state in a global table (`MyMod = MyMod or {}`), store event handlers in
  `MyMod.handlers` and `Events.X.Remove` them before adding new ones. `ZMCP.tools`, `ZMCP.tickHooks`,
  `ZMCP.scriptSides` and `ZMCP.nextReq` survive a reload of Bridge.lua.
- **No `require` of new files at runtime.** Load new code with `run_file` / `script_install` (loadstring).
  Api files guard their `require` lines so they load both at startup (mod) and through `tools/pz load`.
- Kahlua: no `io`, no `bit`, `tostring()` without an argument throws, overloaded Java methods are chosen by
  argument count. Return only plain tables/strings/numbers/booleans from tools; userdata is `tostring`ed.
- Keep big data (textures, snapshots) in files, not in ModData.

## Dev workflow on the live server

Deployment specifics come from `~/.config/zomboid-mcp/local.env`; `tools/pz` and `tools/deploy_server.sh`
source it.

- `tools/pz status | call <tool> [json] | eval "<lua>" | events [n] | bench` talk to the bridge through the
  file protocol; `pz poll` triggers one paused-server poll by hand, `pz console "<cmd>"` and `pz log` reach
  the server console. `ZMCP_POLL_FILE=VappsGuardian.lua` is set in `local.env` until the mount exists.
- `tools/pz load` uploads `Json.lua`, `Bridge.lua` and `Api/*.lua` as `zmcp_src_*.lua` plus a generated
  `zmcp_boot.lua` loader into the Lua dir and runs the loader on the live server: through the bridge's own
  `run_file` when the heartbeat is fresh, otherwise through the console (`reloadlua` of the poll file). No
  restart, works while paused. Before the mount exists this relies on `tools/pz bootstrap`, which appends
  `tools/dev_bootstrap.lua` to `/opt/zomboid-lua/vapps/VappsGuardian.lua` (pristine copy kept as
  `VappsGuardian.lua.orig`): on every `reloadlua VappsGuardian.lua` that block runs a new `zmcp_boot.lua`
  (stamped, so it loads only once per upload) or just polls the bridge. It also brings the bridge back
  automatically after a server start. This is installed on the live server since 2026-09-29.
- `tools/pz run file.lua` executes a local Lua file once on the server (uploaded as `zmcp_run.lua`).
- `tools/deploy_server.sh` syncs the server Lua to `/opt/zomboid-lua/ZomboidMCP` on the host. That directory
  is meant to be bind-mounted read-only into the container at
  `/home/steam/pz-dedicated/media/lua/server/ZomboidMCP` so the files load at startup and can be reloaded
  with `reloadlua Bridge.lua`. **The mount does not exist yet**; it is a compose change for the owner
  (ZOM deploy), like the old `vapps` mount. Until then `tools/pz load` is the way to get code into the server.
- Tests: `make test` runs everything offline (see README). `tests/run_lua_tests.py` runs `tests/json_test.lua` under a
  standalone Lua 5.1 (`lua5.1`/`luajit` on PATH, else the `lupa` wheel: `pip install lupa`).
  `tests/live/bridge_smoke.py` runs 16 checks against the live server through the file protocol: ping,
  run_lua_server (values, errors, compile errors), tools_list, ordering, latency under 1 s, gap handling, resync
  after a lower server counter, stale and malformed requests, script_install/list/remove, run_file, events,
  cleanup. `tests/live/mcp_smoke.py` does the same through the MCP server. Run them with the env exported:
  `set -a; . ~/.config/zomboid-mcp/local.env; set +a; python3 tests/live/bridge_smoke.py`.

# Part 2: server ⇄ client commands (module `zmcp`)

The command protocol between the server (`Api/Visuals.lua`, plus any tool or script that calls
`ZMCP.toClients`) and the client mod (`client/ZomboidMCP/Client.lua` and its submodules). Every player with the
Workshop mod runs the client.

## Transport

- **Server → client:** `sendServerCommand([player,] "zmcp", command, args)`, received by
  `Events.OnServerCommand(module, command, args)`. `ZMCP.toClients(command, args, player)` wraps it and, in
  single player (same Lua state, `sendServerCommand` is a no-op), calls `ZMCPClient.onCommand` directly.
- **Client → server:** `sendClientCommand(player, "zmcp", command, args)`, received by
  `Events.OnClientCommand(module, command, player, args)` (`ZMCP.visuals.onClientCommand`). This also
  works in single player (`SinglePlayerServer` fires the event).
- `args` is a flat table of strings, numbers and booleans. Nested data travels as a string (`"x,y,z;x,y,z"`
  paths, `"x,y,z,delay,dur;..."` drop lists, JSON for pixel-sprite definitions).
- Messages are kept under ~3 KB: long payloads (code, base64) are split into `part`/`total` chunks and
  reassembled by `id` on the client. The server sends at most `ZMCP.visuals.PER_TICK` (12) messages per
  tick through a FIFO queue, so ordering is preserved (textures before sprites on a resend).
- Commands addressed to one player are sent with the player argument; the client does not filter by target.
  Unknown commands are logged and ignored. Every handler runs under `pcall`; a failing handler never breaks the
  next one. Client-side effects are **client-authoritative**: the server cannot verify them (tools report
  `sent = true`; the client answers with the result commands below).

## Client → server

| command | args | when |
|---|---|---|
| `hello` | `{version}` | `OnGameStart`. The server answers with every registered texture, model, client script and world sprite (late join / reconnect). Event `client_hello`. |
| `execResult` | `{id, ok, res, ms, module?}` | after every `exec` chunk set ran (`res` = the return value, tables JSON-encoded, or the error; ≤ 4000 chars). Event `client_exec_result`; `client_results {id}` shows `{to, results, pending, done}` and the MCP's `run_lua_client` waits for it. |
| `texResult` | `{id, gen, ok, w?, h?, bytes?, err?}` | after a texture was written and loaded (or failed). Event `client_texture`. |
| `fileResult` | `{id, gen, path, ok, bytes?, err?}` | after a `file` push was written. Event `client_file`. |
| `modelResult` | `{id, gen, name, ok, err?}` | after a `model` registration. Event `client_model`. |
| `pong` | `{version, sprites, textures, models, execs, captured}` | answer to `ping` (`visuals_list` sends one). Event `client_pong`. |

## Server → client

| command | args | effect |
|---|---|---|
| `exec` | `{id, part, total, code, module?}` | chunked Lua. When all parts are in: `loadstring`, `pcall`, reply `execResult`. With `module` (= a client script name), the source is kept in `ZMCPClient.modules[name]`. |
| `scriptRemove` | `{name}` | forget a client script and drop every hook registered under `name` (`ZMCPClient.off(name)`). |
| `file` | `{id, gen, part, total, data, path}` | base64 chunks of any file → `~/Zomboid/Lua/<path>` (parent dirs are created; `..` refused). Reply `fileResult`. |
| `model` | `{id, gen, mesh, texture, scale}` | runtime 3D model: once both files (`mesh` = `media/….x`, `texture` = `media/….png`, relative to the Lua dir) are present, `ModelScript.new()` + `setModule(Base)` + `InitLoadPP` + `Load` + `addModelScript` under the name `zmcp_<id>_<gen>`; `ZMCPClient.models.name(id)` returns it. Reply `modelResult`. |
| `capture` | `{on}` | screen apps: the overlay consumes mouse events and is brought to the top (`on`), or is released (click-through, `backMost`). |
| `tex` | `{id, gen, part, total, data}` | base64 PNG chunk. Complete → decoded (pure Lua, arithmetic only) into `~/Zomboid/Lua/zmcp_tex_<id>_<gen>.png` via `getFileOutput`, loaded with `getTexture(absolutePath)`. New generation = new file name because textures are cached by path. Reply `texResult`. |
| `pixel` | `{id, def}` | art without a PNG: `def` = JSON `{w, h, palette = {a = [r,g,b,a]}, rows = ["aab.", ...]}`, drawn with `drawRect`. Usable wherever a texture id is. |
| `sprite` | `{id, tex, x, y, z, scale?, tiles?, path?, speed?, loop?, bob?, bobHz?, flip?, opacity?, ttl?, fade?, anchor?}` | create/replace a world sprite (see Rendering). |
| `spriteRemove` | `{id?}` | remove one sprite, or all without `id`. |
| `fall` | `{id, item, items, scale?, tex?}` | falling item icons; `items` = `"x,y,z,delay,dur;..."` (target tile, seconds until the drop starts, fall duration). Visual only: the server spawns the real items. |
| `draw` | `{id?, kind, anchor, x, y, z?, x2?, y2?, z2?, w?, h?, r?, g?, b?, a?, ttl?, text?, font?, centre?, fill?, thick?, tex?, flip?}` | overlay primitive: `line`, `rect`, `text`, `texture`; `anchor` = `screen` (px, negative = from right/bottom) or `world` (tiles; sizes in px at zoom 1). `ttl` seconds, absent = until cleared. |
| `notify` | `{text, ttl?, r?, g?, b?, font?}` | message box at the top of the screen (stacked, fades). |
| `halo` | `{text, r?, g?, b?, time?}` | `setHaloNote` on the local player (overhead text). |
| `chat` | `{text, r?, g?, b?}` | a line in the chat panel (`ISChat.addLineInChat`); falls back to `notify` when the chat API differs. |
| `say` | `{text}` | speech bubble on the local player. |
| `heal` | `{}` | client-authoritative: every body part `RestoreToFullHealth`, stiffness cleared, pain/panic/stress/fatigue/hunger/thirst reset, `sendPlayerStatsChange`. |
| `cure` | `{}` | client-authoritative: zombie infection and wound infection cleared on every body part and on `BodyDamage`. |
| `teleport` | `{x, y, z?}` | `player:teleportTo` (position is client-authoritative in MP). |
| `clear` | `{what?, id?}` | `all` (sprites, overlays, falling items, notices, every script hook, capture off), `sprites`, `overlays`, `falling`, `notices`, `textures` (forget loaded textures; files stay), `models`, `hooks` (one name with `id`, or all). |
| `ping` | `{}` | reply `pong`. |

`heal`, `cure`, `teleport`, `halo`, `notify`, `chat` and `say` are meant for server scripts too:
`ZMCP.toClients("heal", {}, ZMCP.player("niach"))`.

## Rendering

- One full-screen `ISUIElement` (`ZMCPOverlay`) with `setConsumeMouseEvents(false)` is added to the UI
  manager and sent `backMost()` on `OnGameStart`: it draws above the world and below the vanilla UI, and
  clicks pass through. Its `render` draws, in order: world sprites, falling items, overlay primitives and
  notices, then every render hook registered by pushed code (a hook that errors is removed and logged).
- **World sprites** are drawn bottom-centre at `isoToScreenX/Y(0, x, y, z)`, always on top (owner
  preference, no occlusion), ordered by `z` then `x + y` so southern sprites overlap northern ones.
  Size: `scale` multiplies the texture's pixel size at zoom 1, or `tiles` gives the width in world tiles
  (64 px at zoom 1); both are divided by `getCore():getZoom(0)`.
  Motion: `path` waypoints (from `x,y,z`) walked at `speed` tiles/s with `loop` = `loop` | `pingpong` |
  `once`; `bob` px hop (`bobHz`); `flip` = `auto` (mirror when moving left on screen), `0`, `1`;
  `opacity`, `ttl` (seconds; a sprite with a ttl is not persisted for late joiners), `fade` (in/out seconds),
  `anchor` = `bottom` | `center`.
- **Textures** for sprites/draws are resolved through `ZMCPClient.tex.get(ref)`: an uploaded id, a pixel
  sprite id, `item:Base.Banana` (inventory icon via `instanceItem`), or any vanilla texture name/path
  accepted by `getTexture`.
- **Falling items** use the item's inventory icon (`item:<type>`), a quadratic drop from 700 px (at zoom
  1) with a growing shadow, one small bounce and a fade while the real item appears.

## Server-side registry (Api/Visuals.lua)

`ModData "ZomboidMCP".visuals = { textures = {id → {file, gen, chars} | {pixel = json}}, models = {id → {meshSrc,
texSrc, gen, scale, mesh, texture}}, sprites = {id → args}, cscripts = {name → {file}} }`. Only metadata is stored;
the data lives in files in the Lua cache dir (`zmcp_tex_<id>.b64`, `zmcp_model_<id>.x.b64` / `.png.b64`,
`zmcp_cscript_<name>.lua.txt`), read and streamed on demand (server heap). Late joiners get, in order, textures,
models, client scripts, sprites.

Upload flow through the MCP: `texture_upload {id, png_path}` (or `png_base64`) and `model_upload {id, mesh_path,
png_path, scale}`; the MCP base64-encodes local files, the game copies the base64 into its own file and streams
it. Then `world_sprite {texture: <id>, ...}` or `model_place {id, x, y, z}`. `client_texture` / `client_model`
events (events_poll) report every client's load result.

## Pushed code (run_lua_client / client scripts)

`run_lua_client {code, player?, id?}` chunks the code, sends it as `exec`, and returns `{id, to}`; every
recipient answers with `execResult`. `client_results {id}` returns `{to, results = {user = {ok, res, ms}},
pending, done}`; the MCP polls it and returns `{results = {user = {ok, value|error, ms}}, missing}`.
Per-script ids are given (`id`) or generated (`c<n>`); client scripts use `script:<name>`.

The chunk runs on every client with these globals: `ZMCPClient`, `ZMCPJson` and the vanilla client API.
Return a string, number or table (tables are JSON-encoded) and it comes back in the result.

Hook registry for scripts (ClientInput.lua):
```lua
ZMCPClient.on("flappy", "render", function(ui) ui:drawRect(x, y, w, h, a, r, g, b) end)
ZMCPClient.on("flappy", "tick", function(now) ... end)          -- every game tick, now in seconds
ZMCPClient.on("flappy", "keyDown", function(key) ... end)       -- OnKeyStartPressed; "keyUp" = release, "keyHeld"
ZMCPClient.on("flappy", "mouseDown", function(x, y, button) end) -- "mouseUp", "mouseMove"(x, y, dx, dy), "mouseWheel"(delta)
ZMCPClient.capture(true)     -- screen app: the overlay swallows the mouse and sits above the UI; capture(false) releases
ZMCPClient.off("flappy")     -- remove every hook of that name (script_remove and clear hooks do this)
ZMCPClient.input.keyDown(key), ZMCPClient.input.mouse()   -- polling: isKeyDown, getMouseX/Y, buttons
ZMCPClient.screen(), ZMCPClient.zoom(), ZMCPClient.player(), ZMCPClient.now(), ZMCPClient.send(cmd, args)
ZMCPClient.tex.get(ref), ZMCPClient.tex.draw(ui, entry, x, y, w, h, alpha, flip), ZMCPClient.sprites, ZMCPClient.draw, ZMCPClient.models.name(id)
```
A hook that throws is removed after the first error and logged once (never every frame). Keyboard hooks
fire regardless of capture; the game's own keybinds still fire too, so prefer keys the game does not use.
Convention for client scripts: register hooks under the script name so `script_remove` drops them.

## Dev loop

- Single player: `dev/bundle_sp.sh [test.lua]` concatenates the whole mod (shared + server + client) into
  `~/Zomboid/Lua/zmcp_dev_exec.lua` for the `dev/ZMCPDev` watcher; then drive it with
  `tools/zmcp_client.py --local call <tool> '<json>'` (request files in `~/Zomboid/Lua`). The game only runs
  Lua while it is focused (single player pauses when unfocused). Only one agent at a time, with the owner's OK.
- Offline: `python3 tests/sim/test_sim.py` runs the same files under a standalone Lua 5.1 (`pip install lupa`)
  with mocked engine globals (`tests/sim/sim_prelude.lua`) and exercises the whole path: hello, texture chunks →
  PNG file → texture, sprites, falling items and landings, exec round trip, hooks and input capture, models,
  client and server scripts, late-join resend, request files. `tests/luacheck.py` is the syntax check.
