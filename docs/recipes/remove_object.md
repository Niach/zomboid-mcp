# remove_object

Tool: `remove_object` (server). Remove a tile object by sprite name or index; synced.

```lua
-- server
local x, y, z, sprite = 6402, 5500, 0, "walls_exterior_wooden_01_2"
local sq = getCell():getGridSquare(x, y, z)
if not sq then error("square not loaded") end
local objs, removed = sq:getObjects(), {}
for i = objs:size() - 1, 0, -1 do                     -- backwards: removal shifts indices
    local o = objs:get(i)
    local name = o:getSprite() and o:getSprite():getName()
    if name == sprite and o ~= sq:getFloor() then
        sq:transmitRemoveItemFromSquare(o)            -- removes locally and on clients
        removed[#removed + 1] = i
    end
end
return removed
```

List what is on a square first:

```lua
local out = {}
local objs = sq:getObjects()
for i = 0, objs:size() - 1 do
    local o = objs:get(i)
    out[#out + 1] = { index = i, sprite = o:getSprite() and o:getSprite():getName(), type = o:getObjectName(), floor = (o == sq:getFloor()) }
end
return out
```

Notes: removing the floor leaves a hole (players fall through on upper levels); the tool refuses unless `force`.
