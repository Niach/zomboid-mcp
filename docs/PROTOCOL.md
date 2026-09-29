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
| `zmcp_events.log` | server | append-only event log, one JSON object per line: `{"t", "kind", "data"}` |
| `zmcp_mod_<name>.lua.txt` | server | persistent modules written by `module_install {name, code}` |
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
   - otherwise the tool is still running (a long `lua_eval`).

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
  "tools": ["lua_eval", "module_install", "..."],
  "modules": ["snail"],
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
| `module_install` | `{name, code}` or `{name, file}` | writes `zmcp_mod_<name>.lua.txt` (when `code` is given), runs it, and records it in ModData so it runs again on every bridge load and server start |
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
- Tests: `tests/run_lua_tests.py` runs `tests/json_test.lua` under a standalone Lua 5.1 (`lua5.1`/`luajit`
  on PATH, else the `lupa` wheel: `python3 -m venv .venv && .venv/bin/pip install lupa`).
  `tests/smoke_live.py` runs 16 checks against the live server through the file protocol: ping, lua_eval
  (values, errors, compile errors), tools_list, ordering, latency under 1 s, gap handling, resync after a
  lower server counter, stale and malformed requests, module_install/list/remove, run_file, events, cleanup.
  Run it with the env exported: `set -a; . ~/.config/zomboid-mcp/local.env; set +a; tests/smoke_live.py`.
