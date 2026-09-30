# Supply drop

A crate falls from the sky (an item icon or an uploaded parachute texture), lands with a thump, and a real crate with
loot is placed on the square; a beacon marks it for everyone.

## Calls

```json
[
  {"tool": "players_list", "args": {}},
  {"tool": "server_message", "args": {"text": "Supply drop inbound!", "mode": "notify", "ttl": 6}},
  {"tool": "falling_items", "args": {"item": "Base.Bag_DuffelBag", "count": 1, "x": 6408, "y": 5502, "z": 0, "radius": 0, "duration": 0, "fall": 3, "spawn": false, "scale": 3}},
  {"tool": "overlay_draw", "args": {"id": "drop", "kind": "rect", "anchor": "world", "x": 6408, "y": 5502, "z": 0, "w": 40, "h": 40, "r": 1, "g": 0.8, "b": 0.1, "fill": false, "thick": 3, "ttl": 120}},
  {"tool": "run_lua_server", "args": {"code": "-- the landing script below", "timeout_s": 30}},
  {"tool": "events_poll", "args": {"kinds": ["supply_drop"]}},
  {"tool": "world_query", "args": {"x": 6408, "y": 5502, "z": 0, "radius": 1, "what": "objects"}}
]
```

`falling_items` with `spawn = false` is the animation only (a duffel bag icon, 3× size, 3 s fall; any item type
the tool can validate works, or `tex` an uploaded crate PNG). The server script below
waits the same 3 s in a tick hook, then places a real container object with loot and a sound.

## Landing script (server)

```lua
-- server: after 3 s, place a crate container with loot on the square and play a thump
local x, y, z = 6408, 5502, 0
local at = ZMCP.now() + 3
ZMCP.tickHooks.supplyDrop = function(t)
    if t < at then return end
    ZMCP.tickHooks.supplyDrop = nil
    local ok, err = pcall(function()
        local sq = ZMCP.square(x, y, z)
        local crate = IsoObject.new(sq, "crafted_04_1", "Supply crate")   -- a crate sprite; pick one with sprite search
        sq:transmitAddObjectToSquare(crate, -1)
        -- loot on the ground next to it (a plain IsoObject has no container; ground items are the simple path)
        for _, item in ipairs({ "Base.CannedBeans", "Base.CannedBeans", "Base.Apple", "Base.Bandage", "Base.Axe" }) do
            sq:AddWorldInventoryItem(item, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
        end
        playServerSound("ZombieThumpGeneric", sq)
        ZMCP.event("supply_drop", { x = x, y = y, z = z, items = 5 })
    end)
    if not ok then ZMCP.event("supply_drop", { error = tostring(err) }) end
end
return { landing_in = 3 }
```

- For a real openable container use `IsoThumpable.new(getCell(), sq, sprite, false, {})` with a container type
  (`lua_examples "IsoThumpable.new"`, the vanilla carpentry crate), then `obj:getContainer():AddItem(...)`.
- A parachute: `texture_upload {id = "chute"}` then `falling_items {..., tex = "chute"}`; `fall` longer for a slow descent.
- Cleanup: `remove_object {x, y, z, sprite = "crafted_04_1"}` and clear the ground items (`guides/items.md`).
