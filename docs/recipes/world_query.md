# world_query

Tool: `world_query` (server). What is around x,y,z: zombies, tile objects (with sprite names), ground items, vehicles, players.

```lua
-- server
local cx, cy, cz, r = 6400, 5498, 0, 10
local cell = getCell()
if not cell:getGridSquare(cx, cy, cz) then error("square not loaded (only areas near players are loaded)") end
local res = { zombies = {}, objects = {}, items = {}, vehicles = {}, unloaded = 0 }
local seenVehicle = {}
for dx = -r, r do
    for dy = -r, r do
        local sq = cell:getGridSquare(cx + dx, cy + dy, cz)
        if not sq then res.unloaded = res.unloaded + 1 else
            -- zombies (and players): moving objects
            local mo = sq:getMovingObjects()
            for i = 0, mo:size() - 1 do
                local o = mo:get(i)
                if instanceof(o, "IsoZombie") and not o:isDead() then
                    res.zombies[#res.zombies + 1] = { id = o:getID(), x = o:getX(), y = o:getY(), outfit = o:getOutfitName(), crawling = o:isCrawling() }
                end
            end
            -- tile objects: walls, furniture, trees, doors... index 0 is usually the floor
            local floor = sq:getFloor()
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if o ~= floor then
                    -- getSpriteName() first: a placed IsoObject answered nil to getSprite():getName() on the live
                    -- server; the tool (Api/Common.lua U.spriteName) also falls back to getParentObjectName / getTextureName
                    local sprite = o:getSpriteName()
                    if not sprite or sprite == "" then sprite = o:getSprite() and o:getSprite():getName() end
                    res.objects[#res.objects + 1] = { x = sq:getX(), y = sq:getY(), index = i, sprite = sprite,
                        type = o:getObjectName(), name = o:getName() }
                end
            end
            -- ground items
            local wo = sq:getWorldObjects()
            for i = 0, wo:size() - 1 do
                local item = wo:get(i):getItem()
                res.items[#res.items + 1] = { x = sq:getX(), y = sq:getY(), type = item:getFullType(), name = item:getDisplayName() }
            end
            -- vehicles occupy several squares: dedupe by id
            local v = sq:getVehicleContainer()
            if v and not seenVehicle[v:getId()] then
                seenVehicle[v:getId()] = true
                res.vehicles[#res.vehicles + 1] = { id = v:getId(), script = v:getScriptName(), x = v:getX(), y = v:getY() }
            end
        end
    end
end
return res
```

Notes:
- Keep the radius small for objects (a 21×21 area already has hundreds of tiles); the tool caps it at 40 (80 for zombies).
- `ZMCP.zombiesNear(x, y, z, radius)` returns the zombie list directly; `ZMCP.square(x, y, z)` errors nicely when unloaded.
- `remove_object` takes the `sprite`, the `name` (what `place_object` / `collision_place` set, e.g. `ZMCP_collision`)
  or the object index (`i`); `o:getObjectName()` is the Java class name (IsoObject, IsoDoor, IsoTree, IsoWindow...).
