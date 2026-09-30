# World, squares and tiles

Legend: ✔ verified live on 42.21, ○ from the API index / vanilla Lua (not run by this handbook yet).

## Coordinates and loading

- Tiles: `x` grows east, `y` south, `z` is the floor (0 = ground, up to 31). Fractional positions are fine for
  characters; squares are integers. `players_list` gives a starting point.
- ✔ Only squares near online players are loaded. `getCell():getGridSquare(x, y, z)` is nil elsewhere;
  `ZMCP.square(x, y, z)` errors with a clear message. Everything below needs a loaded square.
- Squares group into chunks (`sq:getChunk()`), cells (`getCell()` is the one active `IsoCell`), rooms and buildings
  (`sq:getRoom()`, `sq:getBuilding()`, `sq:getRoomDef():getName()` ○), and the meta grid (`getWorld():getMetaGrid()` ○
  for zones and buildings without loading them).

```lua
-- server: what is on and around a square
local sq = ZMCP.square(6403, 5498, 0)
local info = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), outside = sq:isOutside(), room = nil, objects = {} }
local room = sq:getRoom()
if room then info.room = room:getName() end
local objs = sq:getObjects()
for i = 0, objs:size() - 1 do
    local o = objs:get(i)
    local spr = o:getSprite()
    info.objects[#info.objects + 1] = { index = i, sprite = spr and spr:getName() or nil, type = o:getObjectName(),
        floor = (o == sq:getFloor()) }
end
info.zombies = #ZMCP.zombiesNear(sq:getX(), sq:getY(), sq:getZ(), 5)
return info
```

`world_query {x, y, z, radius, what}` does this for an area (zombies, objects with sprite names, items, vehicles,
players) and reports unloaded squares.

## Tile objects: place, remove, build

✔ A tile object is an `IsoObject` with a sprite name `<sheet>_<n>`; walls, floors, furniture, fences, lamps, signs,
vegetation are all sprites from the vanilla tilesheets. Server-side, synced and saved:

```lua
-- server: place a wooden wall segment, then remove it again (what place_object / remove_object do)
local sq = ZMCP.square(6402, 5500, 0)
local sprite = "walls_exterior_wooden_01_2"
if not IsoSpriteManager.instance:getNamedMap():containsKey(sprite) then error("unknown sprite " .. sprite) end
local obj = IsoObject.new(sq, sprite)                  -- or IsoObject.new(sq, sprite, "Campfire") to name it
sq:transmitAddObjectToSquare(obj, -1)                  -- -1 = append; adds locally and on every client
local index = obj:getObjectIndex()
sq:transmitRemoveItemFromSquare(obj)                   -- undo
return { placed = sprite, index = index }
```

- Tools: `place_object {sprite, x, y, z, name?}`, `remove_object {x, y, z, sprite | index, all?, force?}` (lists the
  square without sprite/index; refuses floors unless `force`), `build_structure {objects = [{x, y, z?, sprite, name?}...]}`
  (≤ 500, per-entry errors collected).
- **Never probe with `getSprite(name)`**: it silently creates a blank sprite for unknown names. Check the named map.
- Solidity, "is a wall", "blocks light" come from the sprite's properties automatically
  (`getSprite(name):getProperties():has(IsoFlagType.solid)` ○ after `containsKey`).
- Doors, windows, containers, lights, stoves are their own classes (`IsoDoor.new`, `IsoWindow.new`, `IsoThumpable.new`
  for player-built barricadable objects, `IsoLightSwitch`...): a plain `IsoObject` with a door sprite is only a picture.
  `lua_examples "IsoThumpable.new"` shows the vanilla carpentry shapes.
- Removing vanilla map objects is irreversible without a map reset. Removing a floor leaves a hole.

### Finding sprite names

```lua
-- server (or client): search the ~60k loaded sprite names (a one-off copy into a Lua table; do it rarely)
local q, limit = "walls_exterior_wooden_01", 40
local map = IsoSpriteManager.instance:getNamedMap()
local t = transformIntoKahluaTable(map)
local names = {}
for name in pairs(t) do
    if string.find(name, q, 1, true) then names[#names + 1] = name end
end
table.sort(names)
while #names > limit do table.remove(names) end
return { total = map:size(), matches = names }
```

Sheet families: `walls_*` (N/W faces and corners are consecutive numbers in one sheet), `floors_*`, `furniture_*`,
`fixtures_*` (doors, windows, sinks, counters), `vegetation_*`, `lighting_*`, `fencing_*`, `carpentry_*` (player-built),
`blends_*` (terrain), `location_*` (map buildings), `constructedobjects_*`, `camping_*`, `farm_*`. Tile numbers per sheet
are in the mod (`ZMCP.tileSheets["walls_exterior_wooden_01"]` = count). Check the numbers in-game before assuming
`_0` is the west wall: conventions differ per sheet.

### A small building

```lua
-- server: a 4x4 wooden hut with a floor, around cx,cy (what the tile-house recipe does)
local cx, cy, z = 6420, 5510, 0
local WALL_W, WALL_N, FLOOR = "walls_exterior_wooden_01_0", "walls_exterior_wooden_01_1", "floors_interior_tilesandwood_01_40"
local plan = {}
for i = 0, 3 do
    plan[#plan + 1] = { x = cx, y = cy + i, sprite = WALL_W }        -- west wall
    plan[#plan + 1] = { x = cx + i, y = cy, sprite = WALL_N }        -- north wall
    plan[#plan + 1] = { x = cx + 4, y = cy + i, sprite = WALL_W }    -- east wall = west face of the next column
    plan[#plan + 1] = { x = cx + i, y = cy + 4, sprite = WALL_N }    -- south wall = north face of the next row
    for j = 0, 3 do plan[#plan + 1] = { x = cx + i, y = cy + j, sprite = FLOOR } end
end
local map, placed, errors = IsoSpriteManager.instance:getNamedMap(), 0, {}
for n, e in ipairs(plan) do
    local sq = getCell():getGridSquare(e.x, e.y, z)
    if not sq then errors[#errors + 1] = n .. ": not loaded"
    elseif not map:containsKey(e.sprite) then errors[#errors + 1] = n .. ": unknown sprite " .. e.sprite
    else sq:transmitAddObjectToSquare(IsoObject.new(sq, e.sprite), -1); placed = placed + 1 end
end
return { placed = placed, errors = errors }
```

Undo: the same loop with `transmitRemoveItemFromSquare` for every object whose sprite is in the plan (or
`remove_object` per square). Keep a batch under a few hundred objects: every placement is a packet per client.

## Lights, fire, sounds, blood

- ○ `getCell():addLamppost(x, y, z, r, g, b, radius)` returns an `IsoLightSource`; `removeLamppost(light)` undoes it
  (server side, from the signature; not verified live).
- ○ `IsoFireManager.StartFire(cell, sq, ignite, life)` starts a fire (`lua_examples "StartFire"`); fires spread and
  burn buildings: ask first.
- ✔ `playServerSound("ZombieThumpGeneric", sq)` plays an FMOD event at a square for everyone in range;
  ○ `addSound(nil, x, y, z, radius, volume)` is a world sound that attracts zombies.
- ✔ `addBloodSplat(sq, n)` ○ decorates a square.

```lua
-- server: a lamppost next to the player for 60 s (tick hook removes it)
local p = ZMCP.player()
local light = getCell():addLamppost(math.floor(p:getX()) + 1, math.floor(p:getY()), math.floor(p:getZ()), 1.0, 0.8, 0.4, 10)
local until_ = ZMCP.now() + 60
ZMCP.tickHooks.lamp = function(t)
    if t >= until_ then
        pcall(function() getCell():removeLamppost(light) end)
        ZMCP.tickHooks.lamp = nil
    end
end
return "lamp on"
```

## Per-square data and distances

- `sq:getModData()` is a Lua table saved with the square; `sq:transmitModData()` ○ syncs it.
- `IsoUtils.DistanceTo(x1, y1, x2, y2)` ○ or plain `math.sqrt`. `IsoDirections.fromString("SE")`, `IsoDirections.N .. NW`.
- `sq:getMovingObjects()` holds players, zombies and animals on the square; `instanceof(o, "IsoZombie")` /
  `"IsoPlayer"` / `"IsoAnimal"` to tell them apart.
- `getCell():getZombieList()` is every loaded zombie; `getCell():getVehicles()` every loaded vehicle (a Java `Set`;
  wrap `:size()` in `pcall`).
