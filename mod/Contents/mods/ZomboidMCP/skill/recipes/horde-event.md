# Horde event

A timed event: warning, storm and lightning, a horde spawning at the edge of the area, a countdown HUD, and cleanup.
**Ask the owner first**: it is dangerous for players.

## Calls

```json
[
  {"tool": "players_list", "args": {}},
  {"tool": "server_message", "args": {"text": "Something is coming from the east...", "mode": "notify", "ttl": 8, "r": 1, "g": 0.3, "b": 0.3}},
  {"tool": "set_weather", "args": {"kind": "storm", "intensity": 0.9}},
  {"tool": "run_lua_server", "args": {"code": "getClimateManager():transmitServerTriggerLightning(6420, 5498, true, true, true) return true"}},
  {"tool": "spawn_zombies", "args": {"x": 6420, "y": 5498, "z": 0, "count": 25, "outfit": "Inmate", "female_chance": 30}},
  {"tool": "spawn_zombies", "args": {"x": 6420, "y": 5504, "z": 0, "count": 25}},
  {"tool": "overlay_draw", "args": {"id": "horde", "kind": "text", "anchor": "screen", "x": 20, "y": 60, "text": "HORDE: survive 3 minutes", "font": "large", "r": 1, "g": 0.2, "b": 0.2, "ttl": 180}},
  {"tool": "world_query", "args": {"x": 6410, "y": 5500, "z": 0, "radius": 30, "what": "zombies"}},
  {"tool": "kill_zombies_area", "args": {"x": 6410, "y": 5500, "z": 0, "radius": 40}},
  {"tool": "set_weather", "args": {"kind": "clear"}},
  {"tool": "clear_visuals", "args": {"what": "overlays", "id": "horde"}}
]
```

Spawn 15 to 25 tiles from the players (squares must be loaded: within the players' area), in two or three groups so
they approach from a direction. `world_query what=zombies` shows who they target. `kill_zombies_area` ends it (bodies
stay; `zed:removeFromWorld()` in a loop removes bodies-to-be without a corpse).

## As one server script with a countdown

```lua
-- server script "horde": spawns waves every 30 s for 3 minutes east of the first player, then reports
Horde = Horde or {}
if Horde.stop then Horde.stop() end
local p = ZMCP.player()
local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
Horde.state = { started = ZMCP.now(), waves = 0, spawned = 0 }
ZMCP.toClients("notify", { text = "A horde is coming from the east!", ttl = 8, r = 255, g = 60, b = 60 })
ZMCP.tickHooks.horde = function(t)
    local s = Horde.state
    local elapsed = t - s.started
    if elapsed > 180 then Horde.stop(); return end
    if s.waves < math.floor(elapsed / 30) + 1 then
        s.waves = s.waves + 1
        local sq = getCell():getGridSquare(px + 20, py + ZombRand(-4, 5), pz)
        if sq then
            local list = addZombiesInOutfit(sq:getX(), sq:getY(), pz, 10, nil, 50)
            s.spawned = s.spawned + list:size()
            ZMCP.event("horde_wave", { wave = s.waves, spawned = list:size() })
            ZMCP.toClients("draw", { id = "horde", kind = "text", anchor = "screen", x = 20, y = 60, font = "large",
                text = "HORDE wave " .. s.waves .. " / 6", r = 1, g = 0.2, b = 0.2, ttl = 30 })
        end
    end
end
function Horde.stop()
    ZMCP.tickHooks.horde = nil
    ZMCP.toClients("clear", { what = "overlays", id = "horde" })
    ZMCP.toClients("notify", { text = "The horde is over.", ttl = 6 })
    ZMCP.event("horde_end", Horde.state or {})
end
return "horde started"
```

Stop early: `run_lua_server` with `Horde.stop()`, then `kill_zombies_area` / `script_remove {name = "horde"}`.
