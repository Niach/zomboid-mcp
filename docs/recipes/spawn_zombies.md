# spawn_zombies

Tool: `spawn_zombies` (server). `addZombiesInOutfit` spawns a group on a square; synced by the engine.
**Ask the owner before spawning hordes near players.**

```lua
-- server
local x, y, z, count = 6410, 5498, 0, 5
if not getCell():getGridSquare(x, y, z) then error("square not loaded") end
local outfit = "Police"                -- nil = random; names: outfits.md (getAllOutfits)
local femaleChance = 50                -- 0..100
-- (x, y, z, count, outfit|nil, femaleChance) -> ArrayList<IsoZombie>
local list = addZombiesInOutfit(x, y, z, count, outfit, femaleChance)
local ids = {}
for i = 0, list:size() - 1 do ids[#ids + 1] = list:get(i):getID() end
return ids
```

Notes:
- Longer overloads exist (`..., crawler, isFallOnFront, isFakeDead, knockedDown, health, ...`); the 6-argument form is the verified one.
- Zombies wander off and despawn with the normal population logic; to clean up use [kill_zombies_area](kill_zombies_area.md)
  or `zed:removeFromWorld()` (no body).
- Old console equivalents: `createhorde <count> <user>`.
