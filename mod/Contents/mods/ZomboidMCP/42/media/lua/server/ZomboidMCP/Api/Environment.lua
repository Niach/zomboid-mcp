-- Environment tools: set_weather, set_time, lightning, sound, server_message.
require "ZomboidMCP/Bridge"
require "ZomboidMCP/Api/Common"

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
    if a.hour ~= nil then gt:setTimeOfDay(U.num(a, "hour", nil, 0, 24)) end
    if a.day ~= nil then gt:setDay(U.int(a, "day", nil, 1, 31) - 1) end
    if a.month ~= nil then gt:setMonth(U.int(a, "month", nil, 1, 12) - 1) end
    if a.year ~= nil then gt:setYear(U.int(a, "year", nil, 1, 9999)) end
    if a.hour == nil and a.day == nil and a.month == nil and a.year == nil then error("give at least one of hour, day, month, year") end
    local after = Z.timeInfo()
    Z.event("set_time", after)
    return { before = before, after = after }
end)

U.def("lightning", {
    desc = "Trigger a lightning strike at x,y (server-side, synced): flash, optional strike damage/fx and thunder rumble.",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" },
        { "strike", "boolean", false, "actual strike at the square (default true)" },
        { "light", "boolean", false, "flash (default true)" }, { "rumble", "boolean", false, "thunder (default true)" },
    },
}, function(a)
    local x, y = math.floor(U.num(a, "x")), math.floor(U.num(a, "y"))
    local strike, light, rumble = U.bool(a, "strike", true), U.bool(a, "light", true), U.bool(a, "rumble", true)
    getClimateManager():transmitServerTriggerLightning(x, y, strike, light, rumble)
    Z.event("lightning", { x = x, y = y, strike = strike })
    return { x = x, y = y, strike = strike, light = light, rumble = rumble }
end)

U.def("sound", {
    desc = "Play a named game sound at x,y,z for everyone nearby (playServerSound). Names are FMOD events, e.g. 'ZombieThumpGeneric', 'Thunder', 'AlarmClock'.",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" }, { "z", "number", false, "level (default 0)" },
        { "name", "string", true, "sound event name" },
    },
}, function(a)
    local x, y, z = U.pos(a)
    local name = U.str(a, "name")
    local sq = Z.square(x, y, z)
    playServerSound(name, sq)
    return { name = name, x = math.floor(x), y = math.floor(y), z = z }
end)

U.def("server_message", {
    desc = "Show a message to everyone or one player through the Zomboid MCP client mod ('message' command: halo text over the player or a chat line; docs/PROTOCOL.md). Players without the mod see nothing; the console 'servermsg' command is the vanilla fallback.",
    authority = "client", args = {
        { "text", "string", true, "message text" },
        { "name", "string", false, "only this player (default: everyone)" },
        { "mode", "string", false, "halo|chat (default halo)" },
        { "color", "string", false, "'#rrggbb' (default white)" },
    },
}, function(a)
    local text = U.str(a, "text")
    local mode = U.oneOf(a, "mode", { "halo", "chat" }, "halo")
    local color = U.optStr(a, "color")
    local p = a.name and Z.player(tostring(a.name)) or nil
    local msg = { text = text, mode = mode }
    if color then msg.color = color end
    Z.toClients("message", msg, p)
    Z.event("server_message", { text = text, mode = mode, user = p and p:getUsername() or nil })
    return { sent = true, to = p and p:getUsername() or "all", mode = mode, players = #Z.players() }
end)
