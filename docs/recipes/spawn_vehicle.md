# spawn_vehicle

Tool: `spawn_vehicle` (server). `addVehicleDebug` creates a vehicle on a square; the engine syncs it.

```lua
-- server
local x, y, z = 6405, 5498, 0
local sq = getCell():getGridSquare(x, y, z)
if not sq then error("square not loaded") end
local script = "Base.CarNormal"                             -- see vehicle_types.md
if not getScriptManager():getVehicle(script) then error("unknown vehicle script " .. script) end
local v = addVehicleDebug(script, IsoDirections.S, nil, sq)  -- (script, IsoDirections, Integer skin|nil, IsoGridSquare)
if not v then error("addVehicleDebug returned nil (blocked square?)") end
return { id = v:getId(), script = v:getScriptName(), x = v:getX(), y = v:getY() }
```

Notes:
- The square must be outdoors and flat with room for the vehicle; inside buildings or on other vehicles it fails or clips.
- Remove a vehicle: `v:permanentlyRemove()` (server-side). Find it again through `sq:getVehicleContainer()` or
  `getVehicleById(id)`.
- Directions: `IsoDirections.N .. NW`, or `IsoDirections.fromString("SE")`.
