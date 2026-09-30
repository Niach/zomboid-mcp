# Vehicles

Legend: ✔ verified live on 42.21, ○ from the API index / vanilla Lua. Vehicles are server-authoritative and synced.

## Find a script and spawn

```lua
-- server: search vehicle scripts, then spawn one facing south (what spawn_vehicle does)
local q, out = "carnormal", {}
local list = getScriptManager():getAllVehicleScripts()          -- vanilla + car mods (395 on our server)
for i = 0, list:size() - 1 do
    local s = list:get(i)
    if string.find(string.lower(s:getFullName()), string.lower(q), 1, true) then
        out[#out + 1] = { script = s:getFullName(), name = s:getName(), mechanicType = s:getMechanicType() }
    end
end
local sq = ZMCP.square(6405, 5498, 0)
local v = addVehicleDebug("Base.CarNormal", IsoDirections.S, nil, sq)   -- ✔ (script, dir, skin|nil, square)
if not v then error("addVehicleDebug returned nil (blocked square?)") end
return { found = out, spawned = { id = v:getId(), script = v:getScriptName(), x = v:getX(), y = v:getY() } }
```

- Tool: `spawn_vehicle {script, x, y, z, dir}` (short names are matched). The square must be outdoors, flat, with room
  for the vehicle; the vehicle spawns in random condition (follow with `vehicle_fix`).
- Damaged variants are separate scripts (`Base.CarNormalSmashedFront`, `...Burnt`). Skins: the `Integer` argument.
- `getScriptManager():getVehicle("Base.CarNormal")` checks one script.

## Inspect and repair

```lua
-- server: the player's vehicle (or nearest), its parts, then full repair and refuel (what vehicle_fix does)
local p = ZMCP.player()
local v = p:getVehicle()
if not v then
    local best, bd = nil, nil
    for dx = -12, 12 do
        for dy = -12, 12 do
            local sq = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, p:getZ())
            local c = sq and sq:getVehicleContainer()
            if c then
                local d = math.sqrt(dx * dx + dy * dy)
                if not bd or d < bd then bd, best = d, c end
            end
        end
    end
    v = best
end
if not v then error("no vehicle nearby") end
local parts = {}
for i = 0, v:getPartCount() - 1 do
    local part = v:getPartByIndex(i)
    local info = { id = part:getId(), condition = part:getCondition() }
    if part:isContainer() then info.content, info.capacity = part:getContainerContentAmount(), part:getContainerCapacity() end
    parts[#parts + 1] = info
end
v:repair()                                                   -- ✔ every part to full condition, synced
local tank = v:getPartById("GasTank")
tank:setContainerContentAmount(tank:getContainerCapacity())  -- ✔ fill up
v:transmitPartModData(tank)                                  -- ✔ sync the fuel amount
return { id = v:getId(), script = v:getScriptName(), speed = v:getCurrentSpeedKmHour(), engine = v:getEngineQuality(),
         running = v:isEngineRunning(), parts = parts }
```

- Parts: Engine, Battery, GasTank, TireFrontLeft/Right, TireRearLeft/Right, Brake*, Suspension*, Door*, Window*,
  Headlight*, Muffler, TruckBed / GloveBox (containers). `getPartById`, `getPartCount`, `getPartByIndex` are interface
  default methods on the vehicle (not listed by the index; `v:getParts()` has the same, and the mod's `vehicle_fix`
  falls back to `parts:size()` / `parts:get(i)`).
- Battery: `v:getPartById("Battery"):getInventoryItem():setUsedDelta(1.0)` + `v:transmitPartItem(part)` ○.
- Engine quality is separate from condition; `setEngineQuality` is not exposed in 42.21.
- Keys: ○ `v:setHotwired(true)` (no key needed), or `local key = v:createVehicleKey()` then `inv:AddItem(key)` +
  `sendAddItemToContainer(inv, key)`; `v:addKeyToGloveBox()` (`api_search "BaseVehicle:Key"`).
- Vehicles by id: `getVehicleById(id)` ○; on a square: `sq:getVehicleContainer()`; every loaded one:
  `getCell():getVehicles()` (a Java `Set`; pcall `:size()`).
- Who is inside: `v:getDriver()`, `v:getPassenger(i)` ○, `v:getSeat(character)` ○; `p:getVehicle()` from the player side.
- `world_query {what = "vehicles"}` lists id, script, position, speed, engine and driver for an area.

## Move, remove

- ✔ Remove: `v:permanentlyRemove()` (server).
- Teleport a vehicle: ○ `v:setX/Y/Z` + `v:setPhysicsActive(true)` are unreliable; simplest is remove + respawn.
- Driving a vehicle from a script is physics-bound (no reliable "drive to" API); for a moving 3D thing prefer a sprite,
  an actor zombie or the entity layer (`3d-moving-entities.md`).
- Sirens / lights: ○ `v:setHeadlightsOn(true)`, `v:setLightbarSirenMode(n)` for emergency vehicles.
