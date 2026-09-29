-- Discovery tools: status, players_list, player_info, world_query. Read-only, server side.
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.def) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

local MOODLES = { "ENDURANCE", "TIRED", "HUNGRY", "PANIC", "SICK", "BORED", "UNHAPPY", "BLEEDING", "WET", "HAS_A_COLD",
    "ANGRY", "STRESS", "THIRST", "INJURED", "PAIN", "HEAVY_LOAD", "DRUNK", "DEAD", "ZOMBIE", "HYPERTHERMIA",
    "HYPOTHERMIA", "WINDCHILL", "CANT_SPRINT", "UNCOMFORTABLE", "NOXIOUS_SMELL", "FOOD_EATEN" }
local STATS = { "HUNGER", "THIRST", "FATIGUE", "ENDURANCE", "PANIC", "STRESS", "BOREDOM", "UNHAPPINESS", "PAIN",
    "SICKNESS", "WETNESS", "TEMPERATURE", "INTOXICATION", "ZOMBIE_INFECTION" }

local function timeInfo()
    local gt = getGameTime()
    return {
        hour = U.round(gt:getTimeOfDay(), 2), day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear(),
        daysSurvived = U.try(function() return gt:getDaysSurvived() end),
        nightsSurvived = U.try(function() return gt:getNightsSurvived() end),
    }
end
Z.timeInfo = timeInfo

local function weatherInfo()
    local cm = getClimateManager()
    local wp = U.try(function() return cm:getWeatherPeriod() end)
    local running = wp and U.try(function() return wp:isRunning() end) or false
    return {
        raining = cm:isRaining(), rain = U.round(cm:getRainIntensity(), 2),
        snowing = U.try(function() return cm:isSnowing() end), snow = U.round(U.try(function() return cm:getSnowIntensity() end) or 0, 2),
        storm = running and U.try(function() return wp:isThunderStorm() end) or false,
        tropical = running and U.try(function() return wp:isTropicalStorm() end) or false,
        blizzard = running and U.try(function() return wp:isBlizzard() end) or false,
        weatherRunning = running,
        temperature = U.round(cm:getTemperature(), 1), fog = U.round(cm:getFogIntensity(), 2),
        wind = U.round(cm:getWindIntensity(), 2), clouds = U.round(cm:getCloudIntensity(), 2),
        daylight = U.round(cm:getDayLightStrength(), 2),
    }
end
Z.weatherInfo = weatherInfo

-- The bridge (Bridge.lua) registers a plain `status` (heartbeat data). This one adds weather and loaded counts on top
-- of it; the original function is kept across Api reloads.
local prev = Z.tools.status
if prev and not prev.api then Z.bridgeStatus = prev.fn end
U.def("status", {
    desc = "Server snapshot: bridge heartbeat (version, paused, players with position/health, time, tools) plus weather and loaded zombie/vehicle counts.",
    authority = "server", args = {},
}, function()
    local res = Z.bridgeStatus and U.try(Z.bridgeStatus) or {}
    if type(res) ~= "table" then res = {} end
    res.version = res.version or Z.version
    res.time = res.time or timeInfo()
    if not res.players then
        local players = {}
        for _, p in ipairs(Z.players()) do players[#players + 1] = U.playerSummary(p) end
        res.players = players
    end
    res.weather = U.try(weatherInfo)
    res.zombiesLoaded = U.try(function() return getCell():getZombieList():size() end)
    res.vehiclesLoaded = U.try(function() return getCell():getVehicles():size() end)
    return res
end)
Z.tools.status.api = true

U.def("players_list", {
    desc = "Online players with username, character name, position, health, access level and vehicle.",
    authority = "server", args = {},
}, function()
    local out = {}
    for _, p in ipairs(Z.players()) do out[#out + 1] = U.playerSummary(p) end
    return out
end)

local function traitsOf(p)
    local out = {}
    local ok = pcall(function()
        U.each(p:getCharacterTraits():getKnownTraits(), function(t)
            local label = U.try(function() return CharacterTraitDefinition.getCharacterTraitDefinition(t):getLabel() end)
            out[#out + 1] = { id = tostring(t:getName()), label = label }
        end)
    end)
    if not ok then return nil end
    return out
end
Z.traitsOf = traitsOf

local function skillsOf(p)
    local out = {}
    U.each(PerkFactory.PerkList, function(perk)
        local parent = U.try(function() return perk:getParent() end)
        if parent and parent ~= Perks.None then
            local lvl = p:getPerkLevel(perk)
            out[#out + 1] = {
                id = perk:getId(), name = U.try(function() return PerkFactory.getPerkName(perk) end),
                level = lvl, xp = U.round(U.try(function() return p:getXp():getXP(perk) end) or 0, 1),
            }
        end
    end)
    return out
end
Z.skillsOf = skillsOf

local function inventoryOf(p, limit)
    local inv = p:getInventory()
    local byType, order = {}, {}
    U.each(inv:getItems(), function(item)
        local t = U.try(function() return item:getFullType() end) or item:getType()
        if not byType[t] then
            byType[t] = { type = t, name = U.try(function() return item:getDisplayName() end) or t, count = 0 }
            order[#order + 1] = t
        end
        byType[t].count = byType[t].count + 1
    end)
    table.sort(order, function(a, b) return byType[a].count > byType[b].count end)
    local items = {}
    for i = 1, math.min(#order, limit or 60) do items[#items + 1] = byType[order[i]] end
    return {
        items = items, distinctTypes = #order,
        count = inv:getItems():size(),
        weight = U.round(inv:getContentsWeight(), 2), maxWeight = U.try(function() return inv:getMaxWeight() end),
        truncated = #order > (limit or 60),
    }
end

local function equippedOf(p)
    local worn = {}
    pcall(function()
        U.each(p:getWornItems():getItems(), function(w)
            local item = w:getItem()
            worn[#worn + 1] = { location = tostring(U.try(function() return w:getLocation():getId() end) or w:getLocation()),
                type = U.try(function() return item:getFullType() end) or item:getType(), name = item:getDisplayName() }
        end)
    end)
    return {
        primary = U.itemInfo(p:getPrimaryHandItem()),
        secondary = U.itemInfo(p:getSecondaryHandItem()),
        worn = worn,
    }
end

local function moodlesOf(p)
    local out = {}
    local m = U.try(function() return p:getMoodles() end)
    if not m then return nil end
    for _, name in ipairs(MOODLES) do
        local mt = U.try(function() return MoodleType[name] end)
        if mt then
            local lvl = U.try(function() return m:getMoodleLevel(mt) end)
            if lvl and lvl > 0 then out[name] = lvl end
        end
    end
    return out
end

local function statsOf(p)
    local out = {}
    local s = U.try(function() return p:getStats() end)
    if not s then return nil end
    for _, name in ipairs(STATS) do
        local v = U.try(function() return s:get(CharacterStat[name]) end)
        if v then out[name] = U.round(v, 3) end
    end
    return out
end

U.def("player_info", {
    desc = "Full picture of one online player: position, health/infection, traits, skills, inventory summary, equipped and worn items, moodles and stats (moodles/stats are the server's copy of client state; may lag).",
    authority = "server", args = {
        { "player", "string", false, "username or character name (optional when exactly one player is online)" },
        { "inventory_limit", "number", false, "max distinct item types in the inventory summary (default 60)" },
    },
}, function(a)
    local p = Z.player(U.optStr(a, "player"))
    local bd = p:getBodyDamage()
    local d = p:getDescriptor()
    local info = U.playerSummary(p)
    info.dir = U.try(function() return tostring(p:getDir()) end)
    info.female = U.try(function() return p:isFemale() end)
    info.profession = U.try(function() return d:getProfession() end)
    info.health = {
        overall = U.round(bd:getOverallBodyHealth(), 1),
        infected = U.try(function() return bd:IsInfected() end),
        infectionLevel = U.round(U.try(function() return bd:getInfectionLevel() end) or 0, 2),
        bleedingParts = U.try(function() return bd:getNumPartsBleeding() end),
        asleep = U.try(function() return p:isAsleep() end),
        godMode = U.try(function() return p:isGodMod() end),
        invisible = U.try(function() return p:isInvisible() end),
    }
    info.hoursSurvived = U.round(U.try(function() return p:getHoursSurvived() end) or 0, 1)
    info.zombieKills = U.try(function() return p:getZombieKills() end)
    info.traits = traitsOf(p)
    info.skills = skillsOf(p)
    info.inventory = inventoryOf(p, U.int(a, "inventory_limit", 60, 1, 500))
    info.equipped = equippedOf(p)
    info.moodles = moodlesOf(p)
    info.stats = statsOf(p)
    return info
end)

local WHAT = { "zombies", "objects", "items", "vehicles", "players", "all" }

U.def("world_query", {
    desc = "List what is in a square area around x,y,z (only loaded squares near players). what = zombies|objects|items|vehicles|players|all. Objects include sprite names (floors skipped unless include_floor).",
    authority = "server", args = {
        { "x", "number", true, "center tile x" }, { "y", "number", true, "center tile y" }, { "z", "number", false, "level (default 0)" },
        { "radius", "number", false, "tiles (default 10, max 40; zombies up to 80)" },
        { "what", "string", false, "zombies|objects|items|vehicles|players|all (default all)" },
        { "limit", "number", false, "max entries per category (default 200)" },
        { "include_floor", "boolean", false, "include floor tiles in objects (default false)" },
    },
}, function(a)
    local x, y, z = U.pos(a)
    local what = U.oneOf(a, "what", WHAT, "all")
    local radius = U.int(a, "radius", 10, 0, 80)
    local limit = U.int(a, "limit", 200, 1, 5000)
    local includeFloor = U.bool(a, "include_floor", false)
    Z.square(x, y, z)   -- clear error when the center is not loaded
    local want = function(k) return what == "all" or what == k end
    local res = { x = math.floor(x), y = math.floor(y), z = z, radius = radius }

    if want("zombies") then
        local list, all = {}, Z.zombiesNear(x, y, z, radius)
        for _, zed in ipairs(all) do
            if #list < limit then list[#list + 1] = U.zombieInfo(zed) end
        end
        res.zombies = list
        res.zombieCount = #all
    end

    if want("players") then
        local list = {}
        for _, p in ipairs(Z.players()) do
            if math.floor(p:getZ()) == z and U.dist(p:getX(), p:getY(), x, y) <= radius + 0.5 then
                list[#list + 1] = U.playerSummary(p)
            end
        end
        res.players = list
    end

    if want("objects") or want("items") or want("vehicles") then
        local r = math.min(radius, 40)
        local objects, items, vehicles, seenV = {}, {}, {}, {}
        local nObj, nItems = 0, 0
        local missing = U.scanSquares(x, y, z, r, function(sq)
            if want("objects") then
                local floor = sq:getFloor()
                U.each(sq:getObjects(), function(o, i)
                    if includeFloor or o ~= floor then
                        nObj = nObj + 1
                        if #objects < limit then
                            local info = U.objectInfo(o, i)
                            info.x, info.y = sq:getX(), sq:getY()
                            objects[#objects + 1] = info
                        end
                    end
                end)
            end
            if want("items") then
                U.each(sq:getWorldObjects(), function(wo)
                    nItems = nItems + 1
                    if #items < limit then
                        local info = U.itemInfo(U.try(function() return wo:getItem() end)) or {}
                        info.x, info.y = sq:getX(), sq:getY()
                        items[#items + 1] = info
                    end
                end)
            end
            if want("vehicles") then
                local v = U.try(function() return sq:getVehicleContainer() end)
                if v then
                    local id = U.try(function() return v:getId() end) or tostring(v)
                    if not seenV[id] then
                        seenV[id] = true
                        if #vehicles < limit then vehicles[#vehicles + 1] = U.vehicleInfo(v) end
                    end
                end
            end
        end)
        if want("objects") then res.objects = objects; res.objectCount = nObj end
        if want("items") then res.items = items; res.itemCount = nItems end
        if want("vehicles") then res.vehicles = vehicles end
        res.unloadedSquares = missing
        res.scanRadius = r
    end
    return res
end)
