# Zombies and actors

Legend: ✔ verified live on 42.21, ○ from the API index / vanilla Lua, ◐ listed as a building block by the scene SDK
issue (used in vanilla, not run by this handbook yet). There are **no human NPCs** in B42 multiplayer: only players,
zombies and animals. A "merchant", "guard" or "companion" is a passive zombie in an outfit.

## Spawn

```lua
-- server: five police zombies on a loaded square (what spawn_zombies does)
local x, y, z, count = 6410, 5498, 0, 5
ZMCP.square(x, y, z)
local outfit, femaleChance = "Police", 50        -- nil = random outfit
local list = addZombiesInOutfit(x, y, z, count, outfit, femaleChance)    -- ✔ ArrayList<IsoZombie>, synced
local ids = {}
for i = 0, list:size() - 1 do ids[#ids + 1] = list:get(i):getID() end
return ids
```

- Tool: `spawn_zombies {x, y, z, count ≤ 100, outfit?, female_chance}`. Longer overloads add `isCrawler, isFallOnFront,
  isFakeDead, isKnockedDown, isInvulnerable, isSitting, health` (`api_search "addZombiesInOutfit"`).
- Outfits: `getAllOutfits(false)` (male, 239 on 42.21) / `getAllOutfits(true)`; examples: Police, PoliceRiot, Fireman,
  Doctor, Nurse, Chef, Waiter, Hunter, Survivalist, Bandit, Biker, Cowboy, Priest, Punk, Student, Tourist, Trader,
  Veteran, Farmer, Hazmat, Inmate, Agent, AirCrew, AmbulanceDriver.
- ○ `createZombie(x, y, z, nil, 0, IsoDirections.S)` makes exactly one zombie and returns it (`palette` 0).
- A horde is dangerous for players: ask first, keep it away from bases, clean up.

## Find, count, kill, remove

```lua
-- server: nearest zombie to the player, how many target them, then kill everything within 10 tiles
local p = ZMCP.player()
local list = ZMCP.zombiesNear(p:getX(), p:getY(), p:getZ(), 15)    -- live zombies in the loaded area
local nearest, nd, targeting = nil, nil, 0
for _, zed in ipairs(list) do
    local d = math.sqrt((zed:getX() - p:getX()) ^ 2 + (zed:getY() - p:getY()) ^ 2)
    if not nd or d < nd then nd, nearest = d, zed end
    if zed:getTarget() == p then targeting = targeting + 1 end
end
local killed = 0
for _, zed in ipairs(ZMCP.zombiesNear(p:getX(), p:getY(), p:getZ(), 10)) do
    zed:setAttackedBy(p)
    zed:Kill(p)                                    -- ✔ Kill needs one argument; Kill(nil) works
    killed = killed + 1
end
return { count = #list, targeting = targeting, nearest = nd, nearestOutfit = nearest and nearest:getOutfitName() or nil, killed = killed }
```

- Tool: `kill_zombies_area {player | x,y,z, radius ≤ 80, killer?}` (bodies stay). `zed:removeFromWorld()` deletes a
  zombie without a body. `getCell():getZombieList()` holds every loaded zombie.
- Per zombie: `getID()`, `getX/Y/Z()`, `getOutfitName()`, `isCrawling()`, `isFemale()`, `getHealth()`, `getTarget()`,
  `isDead()`, `getModData()`.
- Cheap counters on the player: `p:getStats():getNumVisibleZombies()`, `getNumChasingZombies()`,
  `getNumVeryCloseZombies()` ○ (client-computed, server copy).

## Passive puppet zombies (actors)

The pattern the scene SDK builds on: spawn one zombie, make it harmless, dress it, walk it around, let it talk.

```lua
-- server: a passive "merchant" that stands still, faces the player and greets them
Merchant = Merchant or {}
if Merchant.zed and not Merchant.zed:isDead() then pcall(function() Merchant.zed:removeFromWorld() end) end
local p = ZMCP.player()
local x, y, z = math.floor(p:getX()) + 2, math.floor(p:getY()), math.floor(p:getZ())
ZMCP.square(x, y, z)
local list = addZombiesInOutfit(x, y, z, 1, "Trader", 0)
local zed = list:get(0)
zed:setUseless(true)                 -- ◐ passive: no attacking, no chasing
zed:setTarget(nil)
zed:getModData().actor = "merchant"  -- tag it so scripts can find it again
zed:faceLocation(p:getX(), p:getY()) -- ○ turn towards the player
zed:Say("Welcome, survivor. Looking for bananas?")   -- ◐ speech bubble everyone sees
Merchant.zed = zed
return { id = zed:getID(), x = x, y = y }
```

```lua
-- server: walk the actor along waypoints, one leg every few seconds, from a tick hook
MerchantWalk = MerchantWalk or { i = 0, nextAt = 0, path = { { 6405, 5500 }, { 6410, 5500 }, { 6410, 5505 } } }
ZMCP.tickHooks.merchantWalk = function(t)
    local zed = Merchant and Merchant.zed
    if not zed or zed:isDead() then ZMCP.tickHooks.merchantWalk = nil; return end
    if t < MerchantWalk.nextAt then return end
    MerchantWalk.i = MerchantWalk.i % #MerchantWalk.path + 1
    local wp = MerchantWalk.path[MerchantWalk.i]
    zed:pathToLocation(wp[1], wp[2], zed:getZ())     -- ◐ pathfinding walk; pathToLocationF for floats
    MerchantWalk.nextAt = t + 8
end
return "walking"
```

Building blocks (◐ unless marked): `setUseless(true)`, `pathToLocation(x, y, z)` / `pathToLocationF`, `setWalkType`,
`setTarget(nil | character)`, `setCanWalk(bool)`, `setFakeDead(bool)`, `Say(text)`, `faceLocation(x, y)` ○,
`dressInNamedOutfit(name)` + `reloadOutfit()` ○ (change clothes later), `setHealth(n)`, `setAvoidDamage(true)` ○
(does not take damage), `setNoTeeth(true)` ○, `setCrawler(true)`, `getModData()` to tag actors. Find a tagged actor
again by scanning `ZMCP.zombiesNear` for `getModData().actor`. Animation: `zed:PlayAnim(name)` / `PlayAnimUnlooped(name)` ○
(`lua_examples "PlayAnim"` for names). Talking to a player from the server: `ZMCP.toClients("say", {text}, p)`
puts a bubble on the **player**; the zombie's own bubble is `zed:Say`.

Cleanup: `zed:removeFromWorld()` (or `kill_zombies_area` around it). Puppets are real zombies: the population system
may move or despawn them when nobody is near, so scripts should re-spawn on demand rather than assume they persist.

## Zombies reacting to things

- Attract them: ○ `addSound(nil, x, y, z, radius, volume)` (a world sound), or `zed:setTarget(p)`.
- Detect kills: `Events.OnZombieDead.Add(function(zed) end)` (server), `OnWeaponHitCharacter(attacker, target, weapon, damage)`.
- Server-side updates: `OnZombieUpdate` does **not** fire on the dedicated server; poll from `ZMCP.tickHooks`.
- Make one invulnerable for a boss fight: `addZombiesInOutfit(..., isInvulnerable = true, ...)` overload ○ or
  `setAvoidDamage(true)` ○, and give it health with `setHealth(20)` ○.

## Animals

`IsoAnimal` (chickens, cows, sheep, deer...) share the character base: `getCell():getAnimals()` ○,
`sq:getAnimals()`, path with `pathToLocation`. They use their own skeleton (no zombie outfits or attachments).

```lua
-- server: a calm cow next to the player (verified 42.21); breeds: angus, simmental, holstein
local p = ZMCP.player()
local x, y, z = math.floor(p:getX()) + 3, math.floor(p:getY()), math.floor(p:getZ())
local cow = addAnimal(getCell(), x, y, z, "cow", AnimalDefinitions.getDef("cow"):getBreedByName("angus"))
cow:addToWorld()
cow:setDebugStress(0)        -- a stressed animal runs away from everything
return { id = cow:getID(), x = x, y = y }
```

Animals ignore the invisible `collision_place` blockers (`solidtrans` and `solid`, verified live: a paddock of them did
not hold two cows), so there are **no fences for animals through `collision_place`**. Livestock in B42 is held by real
fence tiles: the vanilla tall fences (`fencing_01_8` / `_9` north, `_10` / `_11` west, `WallN` / `WallW` +
`TallHoppable`) placed with `build_structure` are the tiles to try (unverified live; low `fencing_01_1..6` are
hoppable and animals `canClimbFences`). Until that is verified, use animals as set dressing that may wander off.
