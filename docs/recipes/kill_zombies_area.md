# kill_zombies_area

Tool: `kill_zombies_area` (server). Kill every zombie in a radius; bodies stay.

```lua
-- server
local x, y, z, r = 6400, 5498, 0, 10
local killer = ZMCP.player("niach")    -- optional: credits the kill; nil works too
local killed = 0
for _, zed in ipairs(ZMCP.zombiesNear(x, y, z, r)) do   -- loops loaded squares, skips dead zombies
    zed:setAttackedBy(killer)
    zed:Kill(killer)                    -- Kill(IsoGameCharacter); Kill(nil) is fine, a no-arg Kill() does not exist
    killed = killed + 1
end
return { killed = killed }
```

Without the bridge helper:

```lua
local cell, killed = getCell(), 0
for dx = -r, r do for dy = -r, r do
    local sq = cell:getGridSquare(x + dx, y + dy, z)
    if sq then
        local mo = sq:getMovingObjects()
        for i = mo:size() - 1, 0, -1 do
            local o = mo:get(i)
            if instanceof(o, "IsoZombie") and not o:isDead() then o:setAttackedBy(killer); o:Kill(killer); killed = killed + 1 end
        end
    end
end end
```

Notes: `getCell():getZombieList()` holds every loaded zombie (no radius); `zed:removeFromWorld()` deletes without a body.
