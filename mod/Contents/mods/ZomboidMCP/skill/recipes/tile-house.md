# Tile house

A 4×4 wooden hut with a floor, built from vanilla tiles next to the player, and its removal. Server-authoritative,
persistent, visible to everyone (verified live: a wall ring built and cleared).

## Calls

```json
[
  {"tool": "players_list", "args": {}},
  {"tool": "world_query", "args": {"x": 6420, "y": 5510, "z": 0, "radius": 4, "what": "objects"}},
  {"tool": "build_structure", "args": {"objects": [
    {"x": 6420, "y": 5510, "sprite": "walls_exterior_wooden_01_0"}, {"x": 6420, "y": 5511, "sprite": "walls_exterior_wooden_01_0"},
    {"x": 6420, "y": 5512, "sprite": "walls_exterior_wooden_01_0"}, {"x": 6420, "y": 5513, "sprite": "walls_exterior_wooden_01_0"},
    {"x": 6424, "y": 5510, "sprite": "walls_exterior_wooden_01_0"}, {"x": 6424, "y": 5511, "sprite": "walls_exterior_wooden_01_0"},
    {"x": 6424, "y": 5512, "sprite": "walls_exterior_wooden_01_0"}, {"x": 6424, "y": 5513, "sprite": "walls_exterior_wooden_01_0"},
    {"x": 6420, "y": 5510, "sprite": "walls_exterior_wooden_01_1"}, {"x": 6421, "y": 5510, "sprite": "walls_exterior_wooden_01_1"},
    {"x": 6422, "y": 5510, "sprite": "walls_exterior_wooden_01_1"}, {"x": 6423, "y": 5510, "sprite": "walls_exterior_wooden_01_1"},
    {"x": 6420, "y": 5514, "sprite": "walls_exterior_wooden_01_1"}, {"x": 6421, "y": 5514, "sprite": "walls_exterior_wooden_01_1"},
    {"x": 6422, "y": 5514, "sprite": "walls_exterior_wooden_01_1"}, {"x": 6423, "y": 5514, "sprite": "walls_exterior_wooden_01_1"},
    {"x": 6421, "y": 5511, "sprite": "floors_interior_wood_01_0"}, {"x": 6422, "y": 5511, "sprite": "floors_interior_wood_01_0"},
    {"x": 6423, "y": 5511, "sprite": "floors_interior_wood_01_0"}, {"x": 6421, "y": 5512, "sprite": "floors_interior_wood_01_0"},
    {"x": 6422, "y": 5512, "sprite": "floors_interior_wood_01_0"}, {"x": 6423, "y": 5512, "sprite": "floors_interior_wood_01_0"},
    {"x": 6421, "y": 5513, "sprite": "floors_interior_wood_01_0"}, {"x": 6422, "y": 5513, "sprite": "floors_interior_wood_01_0"},
    {"x": 6423, "y": 5513, "sprite": "floors_interior_wood_01_0"}
  ]}},
  {"tool": "place_object", "args": {"x": 6422, "y": 5514, "z": 0, "sprite": "fixtures_doors_01_0", "name": "Front door (decorative)"}},
  {"tool": "remove_object", "args": {"x": 6420, "y": 5510, "z": 0, "sprite": "walls_exterior_wooden_01_0", "all": true}}
]
```

- `_0` / `_1` in `walls_exterior_wooden_01` are the west and north faces; the east wall is the west face of the next
  column, the south wall the north face of the next row. Check the numbers in a sheet before building
  (`guides/world-and-tiles.md`, sprite search); the tool refuses unknown names.
- Floors go on the inner squares; `remove_object` refuses floors unless `force`.
- A door sprite placed as a plain `IsoObject` is a picture: real doors need `IsoDoor` (`lua_examples "IsoDoor.new"`).
- Ask before building next to players; keep batches under a few hundred objects.

## Raw Lua

The loop that generates the plan and places it is in `guides/world-and-tiles.md` ("A small building"). Removal:

```lua
-- server: remove every object of the hut's sprites in the 5x5 area
local cx, cy, z = 6420, 5510, 0
local mine = { walls_exterior_wooden_01_0 = true, walls_exterior_wooden_01_1 = true, floors_interior_wood_01_0 = true }
local removed = 0
for x = cx, cx + 4 do
    for y = cy, cy + 4 do
        local sq = getCell():getGridSquare(x, y, z)
        if sq then
            local objs = sq:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local o = objs:get(i)
                local spr = o:getSprite()
                if spr and mine[spr:getName()] and o ~= sq:getFloor() then
                    sq:transmitRemoveItemFromSquare(o)
                    removed = removed + 1
                end
            end
        end
    end
end
return { removed = removed }
```

(The wood floors were added on top of the existing ground floor, so they are not `sq:getFloor()` and get removed too.)
