# vehicle_fix

Tool: `vehicle_fix` (server). Repair every part and fill the gas tank.

```lua
-- server
local p = ZMCP.player("niach")
local v = p:getVehicle()                                    -- the vehicle they sit in
if not v then                                               -- else: nearest one within 12 tiles
    local best, bd = nil, nil
    for dx = -12, 12 do for dy = -12, 12 do
        local sq = getCell():getGridSquare(p:getX() + dx, p:getY() + dy, p:getZ())
        local c = sq and sq:getVehicleContainer()
        if c then
            local d = math.sqrt(dx * dx + dy * dy)
            if not bd or d < bd then bd, best = d, c end
        end
    end end
    v = best
end
if not v then error("no vehicle nearby") end

v:repair()                                                  -- all parts to full condition (synced)
local tank = v:getPartById("GasTank")                       -- parts: Engine, Battery, GasTank, TireFrontLeft, ...
tank:setContainerContentAmount(tank:getContainerCapacity())
v:transmitPartModData(tank)                                 -- sync the fuel amount
return { id = v:getId(), script = v:getScriptName(), fuel = tank:getContainerContentAmount(), engine = v:getEngineQuality() }
```

Notes:
- `getPartById` / `getPartCount` / `getPartByIndex` are interface default methods on `BaseVehicle` (42.21); `v:getParts()` has the same.
- Battery charge is an item on the "Battery" part: `local b = v:getPartById("Battery"):getInventoryItem(); b:setUsedDelta(1.0); v:transmitPartItem(part)`.
- Engine quality/loudness are separate from part condition (`getEngineQuality`, `setEngineQuality` is not exposed in 42.21).
