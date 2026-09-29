# vehicle_info (parts and condition)

Not a tool: script it.

```lua
-- server
local v = ZMCP.player("niach"):getVehicle()          -- or sq:getVehicleContainer() / getVehicleById(id)
if not v then error("player is not in a vehicle") end
local parts = {}
for i = 0, v:getPartCount() - 1 do
    local part = v:getPartByIndex(i)
    local info = { id = part:getId(), condition = part:getCondition() }
    if part:isContainer() then info.content, info.capacity = part:getContainerContentAmount(), part:getContainerCapacity() end
    parts[#parts + 1] = info
end
return { id = v:getId(), script = v:getScriptName(), x = v:getX(), y = v:getY(), speed = v:getCurrentSpeedKmHour(),
         engineRunning = v:isEngineRunning(), engineQuality = v:getEngineQuality(), parts = parts }
```
