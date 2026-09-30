# build_structure

Tool: `build_structure` (server). Batch `place_object`. Same engine calls in a loop; collect per-entry errors.

```lua
-- server: a 4x4 wooden wall ring with a floor, ground level, around cx,cy
local cx, cy, z = 6420, 5510, 0
local WALL_W, WALL_N, FLOOR = "walls_exterior_wooden_01_0", "walls_exterior_wooden_01_1", "floors_interior_tilesandwood_01_40"
local plan = {}
for i = 0, 3 do
    plan[#plan + 1] = { x = cx, y = cy + i, sprite = WALL_W }        -- west wall
    plan[#plan + 1] = { x = cx + i, y = cy, sprite = WALL_N }        -- north wall
    plan[#plan + 1] = { x = cx + 4, y = cy + i, sprite = WALL_W }    -- east wall (west face of the next column)
    plan[#plan + 1] = { x = cx + i, y = cy + 4, sprite = WALL_N }    -- south wall
    for j = 0, 3 do plan[#plan + 1] = { x = cx + i, y = cy + j, sprite = FLOOR } end
end
local map, placed, errors = IsoSpriteManager.instance:getNamedMap(), 0, {}
for n, e in ipairs(plan) do
    local sq = getCell():getGridSquare(e.x, e.y, e.z or z)
    if not sq then errors[#errors + 1] = n .. ": square not loaded"
    elseif not map:containsKey(e.sprite) then errors[#errors + 1] = n .. ": unknown sprite " .. e.sprite
    else
        sq:transmitAddObjectToSquare(IsoObject.new(sq, e.sprite), -1)
        placed = placed + 1
    end
end
return { placed = placed, errors = errors }
```

Notes:
- Sheet/index conventions differ per sheet; check the tile numbers in `sprite_search` output (and the in-game tile
  picker of the debug build menu) before assuming `_0` is the west wall. Floors: there is no `floors_interior_wood_01`
  sheet in 42.21 (the tool reports `unknown sprite`); wooden floors live in `floors_interior_tilesandwood_01`
  (`_40` Hardwood, `_41` Oakwood, `_42` Birchwood, `_45` Finewood, `_52` Pinewood), carpets in `floors_interior_carpet_01`.
- `world_query {what: "objects"}` lists what you placed with `sprite` and `name`; `remove_object` takes either.
- Clean-up is the same loop with [remove_object](remove_object.md) per entry, or `sq:transmitRemoveItemFromSquare(o)`
  for every object whose sprite name is in your plan.
- Keep batches under a few hundred objects per call: every placement sends a packet to each client.
