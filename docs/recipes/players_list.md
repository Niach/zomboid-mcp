# players_list

Tool: `players_list` (server). Online players with position, health, access level.

```lua
-- server
local out = {}
local list = getOnlinePlayers()
for i = 0, list:size() - 1 do
    local p = list:get(i)
    local d = p:getDescriptor()
    out[#out + 1] = {
        user = p:getUsername(), name = d:getForename() .. " " .. d:getSurname(),
        x = p:getX(), y = p:getY(), z = p:getZ(),
        health = p:getBodyDamage():getOverallBodyHealth(), dead = p:isDead(),
        accessLevel = p:getAccessLevel(), onlineId = p:getOnlineID(),
        vehicle = p:getVehicle() and p:getVehicle():getScriptName() or nil,
    }
end
return out
```

Notes:
- Find one player by name: loop and compare `string.lower(p:getUsername())`. `getPlayerFromUsername()` returned nil on our server.
- `ZMCP.player(name)` does the same lookup (username or "Forename Surname", case-insensitive) and errors with the online list.
