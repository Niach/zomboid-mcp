# Bananas from the sky

Twenty bananas fall around the player, visibly, and become real items on the ground that anyone can pick up. The fall is
a client-side animation (item icon, growing shadow, bounce); each landing spawns the real item on the server.

## Calls

```json
[
  {"tool": "status", "args": {}},
  {"tool": "players_list", "args": {}},
  {"tool": "falling_items", "args": {"item": "Base.Banana", "count": 20, "player": "niach", "radius": 3, "duration": 3, "fall": 1.2, "spawn": true}},
  {"tool": "server_message", "args": {"text": "Bananas!", "mode": "halo", "player": "niach"}},
  {"tool": "events_poll", "args": {"kinds": ["falling_items", "falling_spawn_error"]}},
  {"tool": "world_query", "args": {"x": 6400, "y": 5498, "z": 0, "radius": 4, "what": "items"}}
]
```

1. `status`: the bridge must be `live` (a paused server has nobody online; `wait_for {player}` if needed).
2. `players_list`: the account name and position. `player` centres the rain on them; or pass `x, y, z`.
3. `falling_items`: returns `{id, count, spawning, done_in}`; the real items appear over `duration + fall` seconds.
4. Verify with `world_query what=items` around the position after `done_in` seconds. Squares that unloaded meanwhile
   produce `falling_spawn_error` events.

## Raw Lua (server)

```lua
-- server: the visual is a client command; the items are AddWorldInventoryItem after the fall time
local p = ZMCP.player("niach")
local x, y, z, count, radius = p:getX(), p:getY(), math.floor(p:getZ()), 20, 3
local segs, spawns = {}, {}
for i = 1, count do
    local ang, r = ZombRandFloat(0, 2 * math.pi), math.sqrt(ZombRandFloat(0, 1)) * radius
    local tx, ty = math.floor(x + math.cos(ang) * r), math.floor(y + math.sin(ang) * r)
    local delay, dur = ZombRandFloat(0, 3), 1.2
    segs[#segs + 1] = string.format("%d,%d,%d,%.2f,%.2f", tx, ty, z, delay, dur)
    spawns[#spawns + 1] = { at = ZMCP.now() + delay + dur + 0.1, x = tx, y = ty }
end
ZMCP.toClients("fall", { id = "bananas", item = "Base.Banana", items = table.concat(segs, ";") })
ZMCP.tickHooks.bananas = function(t)
    local keep = {}
    for _, s in ipairs(spawns) do
        if t >= s.at then
            local sq = getCell():getGridSquare(s.x, s.y, z)
            if sq then sq:AddWorldInventoryItem("Base.Banana", ZombRandFloat(0.15, 0.85), ZombRandFloat(0.15, 0.85), 0) end
        else keep[#keep + 1] = s end
    end
    spawns = keep
    if #spawns == 0 then ZMCP.tickHooks.bananas = nil end
end
return { dropping = count }
```

## Variations

- Any item type works (`Base.Apple`, `Base.Katana`, `Base.Money`); `scale` enlarges the icon; `spawn = false` is
  visual only. Up to 200 per call.
- Instead of icons, `tex` an uploaded texture (`texture_upload` first) for a custom falling picture.
- Cleanup: the items are real, players pick them up; or clear ground items in the area (`guides/items.md`).
