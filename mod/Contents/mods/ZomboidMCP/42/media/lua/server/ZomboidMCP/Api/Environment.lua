-- Environment tools: set_weather, set_time. Lightning, sounds and messages are recipes (docs/recipes/).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

Z.tool("set_weather", "Start rain or a thunderstorm, or clear the weather (server-side, synced through the climate manager).", function(a)
    local kind = U.oneOf(a, "kind", { "rain", "storm", "clear" })
    local intensity = U.num(a, "intensity", 0.7, 0, 1)
    local cm = getClimateManager()
    if kind == "rain" then cm:transmitServerStartRain(intensity)
    elseif kind == "storm" then cm:transmitServerTriggerStorm(intensity)
    else
        cm:transmitServerStopWeather()
        pcall(function() cm:transmitServerStopRain() end)
    end
    Z.event("set_weather", { kind = kind, intensity = intensity })
    return { kind = kind, intensity = intensity, weather = U.try(Z.weatherInfo) }
end)

Z.tool("set_time", "Set the game clock: hour (0..24, fractional ok) and optionally day/month/year (1-based). Server-side, synced.", function(a)
    local gt = getGameTime()
    local before = Z.timeInfo()
    if a.hour == nil and a.day == nil and a.month == nil and a.year == nil then error("give at least one of hour, day, month, year") end
    if a.hour ~= nil then gt:setTimeOfDay(U.num(a, "hour", nil, 0, 24)) end
    if a.day ~= nil then gt:setDay(U.int(a, "day", nil, 1, 31) - 1) end
    if a.month ~= nil then gt:setMonth(U.int(a, "month", nil, 1, 12) - 1) end
    if a.year ~= nil then gt:setYear(U.int(a, "year", nil, 1, 9999)) end
    local after = Z.timeInfo()
    Z.event("set_time", after)
    return { before = before, after = after }
end)
