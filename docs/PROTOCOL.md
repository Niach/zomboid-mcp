# Zomboid MCP bridge protocol

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
| `zmcp_events.jsonl` | server | append-only event log, one JSON object per line: `{"t", "kind", "data"}` |
| `zmcp_mod_<name>.lua` | either | persistent modules (see `module_install`) |
| `zmcp_src_*.lua`, `zmcp_boot.lua`, `zmcp_run.lua` | dev tools | scratch files used by `tools/pz load` / `tools/pz run` |

`<n>` is a positive integer without padding. All JSON the MCP writes must be **ASCII only**
(`json.dumps(..., ensure_ascii=True)`, the Python default): the JVM reads the file with its default charset.
The server's JSON output is ASCII too (non-ASCII becomes `\uXXXX`).

## Request numbering

- The server keeps `nextReq`, the number of the next request it will execute. It is persisted in global
  ModData (`ModData.getOrCreate("ZomboidMCP").nextReq`, saved with the world about once a minute) and
  published in `zmcp_status.json`.
- On every tick the server tries to read `zmcp_req_<nextReq>.json`. If it exists it is executed, the
  response is written, and `nextReq` is incremented. Up to 20 requests are processed per tick, strictly in
  order. Everything runs on the game thread, so a tool may touch the world freely.
- The MCP picks `n` like this:
  1. **Resync** (at startup, and after any timeout): read `zmcp_status.json`, list the existing
     `zmcp_req_*.json` files, and set `n = max(status.nextReq, highest existing request + 1)`.
     Delete leftover `zmcp_req_*` / `zmcp_res_*` files older than a couple of minutes.
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
   (withdraw it), read the status and report one of:
   - status older than 5 s: the bridge is not running (server down, or Bridge.lua not loaded);
   - `status.nextReq > n`: the response was lost (should not happen); retry with a new `n`;
   - `status.paused == true`: the game loop is paused (no players online). On 42.21 requests are still
     answered while paused (see below), so this only appears if paused polling stopped working;
   - otherwise the tool is still running (a long `lua_eval`); resync and try again.

The reference implementation does steps 1 to 3 in a single `ssh` exec for the remote transport
(write, poll on the host, cat, delete), which keeps the round trip at roughly one ssh exchange plus one
tick, well under one second with an ssh ControlMaster.

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
  "tools": ["lua_eval", "module_install", "..."],
  "modules": ["snail"],
  "stats": {"requests": 57, "errors": 2}
}
```

"Bridge alive" means `now - status.t < 5`.

## Paused server

Live verification on 42.21 (`PauseEmpty=true`) is in progress in ZOM-1; this section is updated with the
result. Known so far: with no players online `OnTick` and `EveryOneMinute` stop. `Bridge.lua` registers both
`OnTick` and `OnTickEvenPaused`:

- `OnTick` runs the request loop at the game rate (about 10 Hz) while players are online.
- `OnTickEvenPaused` runs it at 5 Hz, but only while no `OnTick` has been seen for one second, so a request
  is never processed twice per tick. It sets `paused=true` in the status.

Consequences for tools: while paused the world does not simulate (no zombies move, time stands still,
world edits are applied but only saved on the next autosave), and objects/squares outside any player's
loaded area are not available. Tools that need a loaded area should say so in their error.

Console commands (`reloadlua`, `players`, ...) also work while paused, so a hot reload never needs a player.

## Events

`zmcp_events.jsonl` grows forever (the server cannot truncate it; the MCP may). Each line is
`{"t": unixSeconds, "kind": "bridge_loaded" | "gap" | "module_install" | "module_remove" | "module_error" | <mod-defined>, "data": {...}}`.
Read it with `tail -c +<offset>` and remember the offset.

## Core tools (registered by Bridge.lua)

| tool | args | result |
|---|---|---|
| `ping` | | `{pong, version, bootId, paused, players}` |
| `status` | | the status document, written fresh |
| `tools_list` | | `[{name, desc}]` |
| `lua_eval` | `{code}` | the chunk's return value (an array when it returns several) |
| `run_file` | `{file}` | runs a Lua file from the Lua dir once; not remembered |
| `module_install` | `{name, code}` or `{name, file}` | writes `zmcp_mod_<name>.lua` (when `code` is given), runs it, and records it in ModData so it runs again on every bridge load and server start |
| `module_list` | | `[{name, file, installed}]` |
| `module_remove` | `{name}` | forgets the module (the file stays; already registered handlers stay until the next restart unless the module removes them itself) |

Errors are returned as `{"ok": false, "error": "<lua error message>"}`; a Lua error inside a tool never
breaks the loop.

## Writing tools and modules (Lua side)

Everything goes through the `ZMCP` table (see the header of `Bridge.lua`):

```lua
ZMCP.tool("hello", "Say hi. args: {name}", function(a)
    return { hi = tostring(a.name), players = ZMCP.playerNames() }
end)
ZMCP.tickHooks.hello = function(t) --[[ runs every processed tick, t = unix seconds ]] end
ZMCP.event("hello", { who = "world" })
```

Rules for every server file (Bridge.lua, Api/*.lua, modules):
- **Re-runnable.** Keep state in a global table (`MyMod = MyMod or {}`), store event handlers in
  `MyMod.handlers` and `Events.X.Remove` them before adding new ones. `ZMCP.tools`, `ZMCP.tickHooks` and
  `ZMCP.nextReq` survive a reload of Bridge.lua.
- **No `require` of new files at runtime.** Load new code with `run_file` / `module_install` (loadstring).
- Kahlua: no `io`, no `bit`, `tostring()` without an argument throws, overloaded Java methods are chosen by
  argument count. Return only plain tables/strings/numbers/booleans from tools; userdata is `tostring`ed.
- Keep big data (textures, snapshots) in files, not in ModData.

## Dev workflow on the live server

Deployment specifics come from `~/.config/zomboid-mcp/local.env`; `tools/pz` and `tools/deploy_server.sh`
source it.

- `tools/pz status | call <tool> [json] | eval "<lua>" | events [n] | bench` talk to the bridge through the
  file protocol.
- `tools/pz load` uploads `Json.lua`, `Bridge.lua` and `Api/*.lua` as `zmcp_src_*.lua` plus a generated
  `zmcp_boot.lua` loader into the Lua dir and runs the loader on the live server: through the bridge's own
  `run_file` when it is alive, otherwise through the console (`reloadlua` of a loaded file that contains the
  dev bootstrap, see `tools/dev_bootstrap.lua`). No restart, works while paused.
- `tools/pz run file.lua` executes a local Lua file once on the server (uploaded as `zmcp_run.lua`).
- `tools/deploy_server.sh` syncs the server Lua to `/opt/zomboid-lua/ZomboidMCP` on the host. That directory
  is meant to be bind-mounted read-only into the container at
  `/home/steam/pz-dedicated/media/lua/server/ZomboidMCP` so the files load at startup and can be reloaded
  with `reloadlua Bridge.lua`. **The mount does not exist yet**; it is a compose change for the owner
  (ZOM deploy), like the old `vapps` mount. Until then `tools/pz load` is the way to get code into the server.
- Tests: `tests/run_lua_tests.py` (Json.lua under a standalone Lua 5.1 via `lupa`, or `lua5.1`/`luajit`),
  `tests/smoke_live.py` (ping, lua_eval, tools_list and latency against the live server).
