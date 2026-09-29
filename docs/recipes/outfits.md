# outfits (zombie outfit names)

Not a tool: script it. 239 male outfits on 42.21 (`getAllOutfits(false)`), the female list is separate.

```lua
-- server
local q, out = "police", {}
for _, female in ipairs({ false, true }) do
    local list = getAllOutfits(female)
    for i = 0, list:size() - 1 do
        local name = list:get(i)
        if string.find(string.lower(name), string.lower(q), 1, true) then out[#out + 1] = name end
    end
end
return out
```

Examples: Agent, AirCrew, AmbulanceDriver, Police, PoliceRiot, Fireman, Doctor, Nurse, Chef, Waiter, Hunter, Survivalist,
Bandit, Biker, Cowboy, Priest, Punk, Redneck, Student, Swimmer, Tourist, Trader, Veteran, Farmer, Hazmat, Inmate...
