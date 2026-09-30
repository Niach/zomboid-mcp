# Performance and safety

Everything here was learned on a live 42.21 dedicated server with real players. Read it before the first script.

## Budgets

| what | limit | why |
|---|---|---|
| one `run_lua_server` chunk | keep under ~100 ms | it runs on the game thread between two ticks; the whole server stalls meanwhile |
| server tick rate | about 10 `OnTick` per second while players are online, 0 while paused | periodic work belongs in `ZMCP.tickHooks.<name>`, not in loops |
| `run_lua_client` chunk | short; never loop waiting | an endless loop freezes that player's game |
| server → client messages | ~3 kB each, 12 per tick (about 1 s per 30 kB of base64) | code, textures and models are chunked by the mod |
| textures | ≤ 256×256 px and ≤ 100 kB PNG where possible; hard limit 1.2 M base64 chars | decode is pure Lua on every client; a 22 kB PNG decodes instantly |
| tool arguments | strings above 32 kB travel as files automatically | nothing to do, just do not paste megabytes |
| client result value | 4000 chars per client | return summaries, not dumps |
| `world_query` | radius ≤ 80 for zombies, ≤ 40 for objects/items | a 21×21 area already has hundreds of tiles |
| batch tools | 200 items, 100 zombies, 500 tile objects, 200 falling items per call | each placement is a packet per client |
| stale requests | refused after 60 s | a request written before a restart can never fire late |
| server heap | 3 GB with about 1.2 GB spare on the host | big data (textures, snapshots) goes to files, never into Lua tables or ModData |

## Every hook under `pcall`

A render or tick hook that throws would throw every frame. The mod removes a failing `ZMCPClient.on` hook after its first
error and logs it once, and `ZMCP.tickHooks` errors are printed and skipped. When you register vanilla events yourself,
wrap the body:

```lua
-- server or client: never let an event handler take the game down
MySafe = MySafe or { handlers = {} }
for ev, fn in pairs(MySafe.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
MySafe.handlers = {}
MySafe.handlers.EveryOneMinute = function()
    local ok, err = pcall(function()
        -- the real work
    end)
    if not ok then
        print("[MySafe] " .. tostring(err))
        Events.EveryOneMinute.Remove(MySafe.handlers.EveryOneMinute)   -- once is enough
    end
end
for ev, fn in pairs(MySafe.handlers) do Events[ev].Add(fn) end
```

## Keep big data in files, not in memory

- `ZMCP.writeFile(name, text)` / `ZMCP.readFile(name)` (server) and `getFileWriter` / `getFileReader` work only inside the
  Lua cache dir (`~/Zomboid/Lua`). `getFileWriter` **refuses** names ending in `.lua` or `.jsonl` and names without an
  extension; `.txt`, `.json`, `.log`, `.lua.txt` work. `getFileReader` reads any name and **throws for a missing file**
  (pcall it, or `fileExists(getMyDocumentFolder() .. "/Lua/" .. name)` with the absolute path first). No delete, list or rename.
- Binary files: `getFileOutput(name)` returns a `DataOutputStream` (`writeByte`), closed with `endFileOutput()`.
  Missing parent directories are created (`media/x.png` under the Lua dir works).
- ModData (`ModData.getOrCreate("MyMod")`) is saved with the world about once a minute: fine for small state
  (ids, counters, positions), wrong for textures or logs.

```lua
-- server: a log line per event, read back the last part
ZMCP.writeFile("mymod_log.txt", (ZMCP.readFile("mymod_log.txt") or "") .. os.date("%H:%M:%S") .. " something happened\n")
local text = ZMCP.readFile("mymod_log.txt") or ""
return string.sub(text, -500)
```

## Cleanup

- Visual: `clear_visuals` (`all` = sprites, overlays, falling items, notices, moving 3D entities and every script hook;
  textures, models and client scripts stay) or by category / id; `entity3d_remove {id | all}` for the 3D layer.
  `ZMCPClient.off("name")` from client code.
- Scripts: `script_remove {name, side}`. A **server** script's event handlers, tools and tick hooks stay alive until the
  next restart unless the script has a `stop()` you run first (convention in `scripts-and-persistence.md`). A **client**
  script's hooks are dropped at once on every client.
- World: remove what you spawned (`remove_object`, `sq:removeWorldObject(wo)`, `zed:removeFromWorld()`,
  `vehicle:permanentlyRemove()`, `kill_zombies_area`). Vanilla map objects removed with `remove_object` are gone until a
  map reset.
- Tick hooks: `ZMCP.tickHooks.myname = nil`.

```lua
-- server: forget a tick hook and a tool you registered earlier
ZMCP.tickHooks.myname = nil
ZMCP.tools.my_tool = nil
return "stopped"
```

## Live-server etiquette

- **Read-only first:** `status`, `players_list`, `world_query`, `player_info`, `events_poll`, `visuals_list`.
- **Ask before:** hordes near players, killing, teleporting or changing a character (traits, skills, health, appearance),
  building next to someone, weather and time jumps during a session, anything through `server_console` that stops the
  server (`quit`) or changes settings, restarts, Workshop uploads.
- **Never** drive the owner's running single-player game without asking: a bad render hook breaks it every frame, and
  the dev exec file is shared between sessions.
- Everything you push is visible to everyone at once. Prefer `player` targeting while testing, `ttl` on sprites and
  overlays, and small counts.
- Verify after acting: `client_texture` / `client_model` / `client_exec_result` / `script_error` events, `world_query`
  after spawns, `player_info` after a teleport (a second later, the client reports its new position).
- `server_console` output goes to the server log; `print()` in server Lua does too, never to you: `return` values instead.

## Paused server and loaded areas

With `PauseEmpty=true` and nobody online the dedicated server fires no Lua event. The MCP polls the bridge through the
console (`reloadlua`) when it can; then requests run on the console thread, the world does not simulate, edits are saved
on the next autosave and no square outside a player's area is loaded. Use `wait_for {player}` before anything that needs
the world. Single-player games also pause while unfocused.
