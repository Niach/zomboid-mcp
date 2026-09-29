-- Environment tools: set_weather, set_time. Lightning, sounds and messages are recipes (docs/recipes/).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.def) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

U.def("set_weather", {
    desc = "Start rain or a thunderstorm, or clear the weather (server-side, synced through the climate manager).",
    authority = "server", args = {
        { "kind", "string", true, "rain|storm|clear" },
        { "intensity", "number", false, "0..1 (default 0.7)" },
    },
}, function(a)
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

U.def("set_time", {
    desc = "Set the game clock: hour (0..24, fractional ok) and optionally day/month/year (1-based). Server-side, synced.",
    authority = "server", args = {
        { "hour", "number", false, "0..24" },
        { "day", "number", false, "day of month 1..31" }, { "month", "number", false, "1..12" }, { "year", "number", false, "e.g. 1993" },
    },
}, function(a)
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
