# spawn_item

Tool: `spawn_item` (server). Drop items on the ground; synced to all clients by the engine.

```lua
-- server
local x, y, z, itemType, count, scatter = 6400, 5498, 0, "Base.Banana", 20, 3
local script = getScriptManager():FindItem(itemType)      -- nil for unknown types
if not script then error("unknown item " .. itemType) end
local cell, placed = getCell(), 0
for i = 1, count do
    local sq = cell:getGridSquare(x + ZombRand(-scatter, scatter + 1), y + ZombRand(-scatter, scatter + 1), z)
    if sq then
        -- (fullType, offsetX 0..1, offsetY 0..1, offsetZ) -> InventoryItem
        local item = sq:AddWorldInventoryItem(script:getFullName(), ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
        if item then placed = placed + 1 end
    end
end
return { placed = placed }
```

Notes:
- `ZombRand(min, max)` is `[min, max)`; `ZombRandFloat(a, b)` is a float in `[a, b)`.
- The `AddWorldInventoryItem` overload with 5 arguments (`..., int`) exists too; keep 4 arguments to get the item back.
- To remove dropped items again: `sq:getWorldObjects()` → `sq:removeWorldObject(wo)` (server-side, synced) or
  `sq:removeAllWorldObjects()`.
