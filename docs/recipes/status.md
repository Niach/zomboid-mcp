# status

Tool: `status` (server). A snapshot of the server: players, game time, weather, loaded zombies/vehicles.

```lua
-- server
local gt, cm = getGameTime(), getClimateManager()
local players = {}
local list = getOnlinePlayers()                       -- ArrayList<IsoPlayer>; empty on a paused/empty server
for i = 0, list:size() - 1 do
    local p = list:get(i)
    players[#players + 1] = {
        user = p:getUsername(), x = p:getX(), y = p:getY(), z = p:getZ(),
        health = p:getBodyDamage():getOverallBodyHealth(), dead = p:isDead(),
    }
end
return {
    players = players,
    time = { hour = gt:getTimeOfDay(), day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear() },
    weather = { raining = cm:isRaining(), rain = cm:getRainIntensity(), temperature = cm:getTemperature(),
                fog = cm:getFogIntensity(), wind = cm:getWindIntensity(), daylight = cm:getDayLightStrength(),
                storm = cm:getWeatherPeriod():isRunning() and cm:getWeatherPeriod():isThunderStorm() },
    zombiesLoaded = getCell():getZombieList():size(),
}
```

Notes:
- `getDay()` / `getMonth()` are 0-based. `getOnlinePlayers()` works on the dedicated server; in single player use `getSpecificPlayer(0)`.
- `getCell():getVehicles()` is a Java `Set`; its runtime class may not be exposed to Lua, so wrap `:size()` in `pcall`.
