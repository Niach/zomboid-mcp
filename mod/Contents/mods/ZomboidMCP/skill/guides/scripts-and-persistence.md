# Scripts and persistence

`run_lua_server` / `run_lua_client` run once. `script_install` makes code **persistent**: it runs now and again on every
bridge reload and server start (side `server`) or on every client now and whenever a player joins (side `client`).
`script_list` shows what is installed, `script_remove` forgets it.

| side | stored as | runs | removed by |
|---|---|---|---|
| `server` (default) | `zmcp_script_<name>.lua.txt` in the Lua dir + ModData | now, on every bridge load, on server start (before players join) | `script_remove`; handlers stay until your `stop()` or a restart |
| `client` | `zmcp_cscript_<name>.lua.txt` on the server, pushed as chunks | now on every connected client, and on each `hello` (join, reconnect) | `script_remove`: clients drop every `ZMCPClient.on` hook registered under the script name |

Sources above 32 kB are moved to a file by the MCP automatically. Read an installed source back with
`run_lua_server`: `return ZMCP.readFile("zmcp_script_<name>.lua.txt")`.

## Re-runnable code (the one rule)

A script runs many times in the same Lua state: on install, on reload, on restart. Keep state in one global table,
remove your event handlers before adding them again, and give it a `stop()`.

```lua
-- server script "greeter": greets every player once a minute, re-runnable, with cleanup
Greeter = Greeter or { handlers = {}, seen = {} }
local G = Greeter
for ev, fn in pairs(G.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
G.handlers = {}

G.handlers.EveryOneMinute = function()
    local ok, err = pcall(function()
        for _, p in ipairs(ZMCP.players()) do
            local user = p:getUsername()
            if not G.seen[user] then
                G.seen[user] = true
                ZMCP.toClients("notify", { text = "Welcome, " .. user, ttl = 5 }, p)
            end
        end
    end)
    if not ok then print("[greeter] " .. tostring(err)) end
end
for ev, fn in pairs(G.handlers) do Events[ev].Add(fn) end

function G.stop()
    for ev, fn in pairs(G.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
    G.handlers = {}
    ZMCP.tickHooks.greeter = nil
end
return "greeter installed"
```

Stop it before `script_remove {name = "greeter"}`: `run_lua_server` with `if Greeter then Greeter.stop() end`.

## Periodic work: tick hooks

`ZMCP.tickHooks.<name> = function(t)` runs on every processed tick (about 10×/s while players are online, and on every
console poll while paused) with `t` = unix seconds. Throttle inside:

```lua
-- server: something every 5 seconds without blocking a tick
MyPulse = MyPulse or { last = 0 }
ZMCP.tickHooks.mypulse = function(t)
    if t - MyPulse.last < 5 then return end
    MyPulse.last = t
    for _, p in ipairs(ZMCP.players()) do
        if p:getBodyDamage():getOverallBodyHealth() < 30 then
            ZMCP.toClients("halo", { text = "Low health!", r = 255, g = 80, b = 80 }, p)
        end
    end
end
return "pulse on"
```

`EveryOneMinute` / `EveryTenMinutes` / `EveryHours` / `EveryDays` are game-time events (a game minute is a few real
seconds at normal speed). On the dedicated server `OnPlayerUpdate` and `OnZombieUpdate` never fire.

## Registering a new MCP tool from a script

`ZMCP.tool(name, description, fn)` registers a game tool; the MCP exposes it as a passthrough tool with a free-form
`args` object on its next `tools/list`. Return a plain table.

```lua
-- server: a tool that counts zombies around a player
ZMCP.tool("zombie_census", "Zombies near a player. args: {player?, radius?}", function(a)
    local p = ZMCP.player(a.player)
    local list = ZMCP.zombiesNear(p:getX(), p:getY(), p:getZ(), tonumber(a.radius) or 20)
    local outfits = {}
    for _, zed in ipairs(list) do
        local o = zed:getOutfitName() or "?"
        outfits[o] = (outfits[o] or 0) + 1
    end
    return { count = #list, outfits = outfits }
end)
return "registered"
```

## ModData: small persistent state

```lua
-- server: a counter that survives restarts (saved with the world about once a minute)
local store = ModData.getOrCreate("MyMod")
store.visits = (tonumber(store.visits) or 0) + 1
return { visits = store.visits }
```

Keys and values must be plain (strings, numbers, booleans, nested tables). Never put base64 or big lists in ModData:
the server heap is tight. `sq:getModData()` and `item:getModData()` are per-object tables that the engine syncs on
`transmitModData()` (squares/objects) and `item:transmitModData()`.

## Client scripts

Same rules on the client, plus: register every hook under the script name so `script_remove` clears it, and call
`ZMCPClient.off(name)` at the top so a re-push replaces instead of duplicating.

```lua
-- sim: client
-- client script "clock": a small HUD in the corner, replaced on every re-install
local NAME = "clock"
ZMCPClient.off(NAME)
ZMCPClient.on(NAME, "render", function(ui)
    local gt = getGameTime()
    local h = gt:getTimeOfDay()
    local text = string.format("Day %d  %02d:%02d", gt:getDay() + 1, math.floor(h), math.floor((h % 1) * 60))
    ui:drawRect(10, 10, 150, 26, 0.5, 0, 0, 0)
    ui:drawText(text, 16, 14, 1, 1, 1, 1, UIFont.Small)
end)
return "clock on"
```

## Hot reload and dev loops

- The bridge itself, its tools and installed scripts reload with the console command `reloadlua ZomboidMCP/Bridge.lua`
  (`server_console`); `ZMCP.tools`, `ZMCP.tickHooks`, `ZMCP.scriptSides` and the request counter survive a reload.
  `reloadlua <file>` only re-runs a file that was loaded at startup, matched by path suffix.
- `require` of a new file at runtime does not work: everything new goes through `script_install` (loadstring).
- Global variables persist between calls in the same state. Use unique global names (`MyMod = MyMod or {}`), never
  bare `state = ...`.
- Compile errors come back as `compile: <message>` with the line; runtime errors as the Lua message. The server keeps
  running either way.
