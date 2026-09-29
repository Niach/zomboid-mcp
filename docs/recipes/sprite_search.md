# sprite_search (tile sprite names)

Not a tool: script it. The sprite manager's named map holds every loaded tile sprite (61k on our server, mods included).
Never probe with `getSprite(name)`: it silently creates a blank sprite for unknown names.

```lua
-- server (or client)
local q, limit = "walls_exterior_wooden_01", 40
local map = IsoSpriteManager.instance:getNamedMap()          -- HashMap<String, IsoSprite>
local t = transformIntoKahluaTable(map)                       -- keys = sprite names (a one-off copy, ~60k entries)
local names = {}
for name in pairs(t) do
    if string.find(name, q, 1, true) then names[#names + 1] = name end
end
table.sort(names)
while #names > limit do table.remove(names) end
return { total = map:size(), matches = names, exists = map:containsKey("walls_exterior_wooden_01_2") }
```

Notes:
- Names are `<sheet>_<n>`. `Api/TileSheets.lua` (`ZMCP.tileSheets`) lists the 425 vanilla sheets with their tile counts
  (`tools/gen_tilesheets.sh` regenerates it from `media/newtiledefinitions.tiles.txt`), useful offline.
- Tile properties: `getSprite(name):getProperties():has(IsoFlagType.solid)` etc. (only after `containsKey`).
- Sheet families: `walls_*`, `floors_*`, `furniture_*`, `fixtures_*`, `vegetation_*`, `location_*` (map buildings),
  `lighting_*`, `blends_*` (terrain), `carpentry_*` (player-built).
