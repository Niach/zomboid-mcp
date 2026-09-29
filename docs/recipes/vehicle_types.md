# vehicle_types (search vehicle scripts)

Not a tool: script it. 395 vehicle scripts on our server (vanilla + car mods).

```lua
-- server
local q, out = "carnormal", {}
local list = getScriptManager():getAllVehicleScripts()
for i = 0, list:size() - 1 do
    local s = list:get(i)
    if string.find(string.lower(s:getFullName()), string.lower(q), 1, true) then
        out[#out + 1] = { script = s:getFullName(), name = s:getName(), mechanicType = s:getMechanicType() }
    end
end
return out
```

Notes: `getScriptManager():getVehicle("Base.CarNormal")` checks one script. Damaged variants exist as separate scripts
(`Base.CarNormalSmashedFront`, `...Burnt`).
