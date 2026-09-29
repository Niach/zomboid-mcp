# place_object

Tool: `place_object` (server). Create a tile object from any sprite and broadcast it.

```lua
-- server
local x, y, z, sprite = 6402, 5500, 0, "walls_exterior_wooden_01_2"
local sq = getCell():getGridSquare(x, y, z)
if not sq then error("square not loaded") end
-- validate the sprite WITHOUT getSprite(name): that call creates an empty sprite for unknown names
if not IsoSpriteManager.instance:getNamedMap():containsKey(sprite) then error("unknown sprite " .. sprite) end
local obj = IsoObject.new(sq, sprite)                 -- or IsoObject.new(sq, sprite, "Campfire") to name it
sq:transmitAddObjectToSquare(obj, -1)                 -- -1 = append; adds locally and sends to clients
return { index = obj:getObjectIndex(), sprite = obj:getSprite():getName() }
```

Notes:
- Sprite names are `<sheet>_<n>`; find them with [sprite_search](sprite_search.md). Wall tiles have N/W variants in the
  same sheet; floors are the `floors_*` sheets; furniture `furniture_*`; vegetation `vegetation_*`; `location_*` are map-specific.
- Solid/collision behaviour comes from the sprite's properties automatically.
- `IsoObject.new(cell, square, spriteObject)` is the 3-argument overload with an `IsoSprite`; the string forms are simpler.
- Special objects (doors, windows, containers, lights) need their own classes (`IsoDoor.new`, `IsoThumpable.new`, ...):
  a plain `IsoObject` with a door sprite is just a picture.
