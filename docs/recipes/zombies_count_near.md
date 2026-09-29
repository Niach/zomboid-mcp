# zombies_count_near

Not a tool: script it (or use `world_query` with `what = "zombies"`).

```lua
-- server
local p = ZMCP.player("niach")
local r = 15
local list = ZMCP.zombiesNear(p:getX(), p:getY(), p:getZ(), r)
local nearest, nd, targeting = nil, nil, 0
for _, zed in ipairs(list) do
    local d = math.sqrt((zed:getX() - p:getX()) ^ 2 + (zed:getY() - p:getY()) ^ 2)
    if not nd or d < nd then nd, nearest = d, zed end
    if zed:getTarget() == p then targeting = targeting + 1 end
end
return { count = #list, targetingPlayer = targeting, nearest = nd,
         nearestOutfit = nearest and nearest:getOutfitName() or nil }
```

Cheap counters on the player itself (client-computed, server copy): `p:getStats():getNumVisibleZombies()`,
`getNumChasingZombies()`, `getNumVeryCloseZombies()`.
