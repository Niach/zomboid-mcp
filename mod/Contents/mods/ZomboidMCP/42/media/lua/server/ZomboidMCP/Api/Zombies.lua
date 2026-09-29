-- Zombie tools: spawn_zombies, kill_zombies_area, zombies_count_near, outfits.
require "ZomboidMCP/Bridge"
require "ZomboidMCP/Api/Common"

local Z = ZMCP
local U = Z.util

U.def("outfits", {
    desc = "List zombie outfit names (for spawn_zombies).",
    authority = "server", args = {
        { "query", "string", false, "substring filter" },
        { "female", "boolean", false, "female outfit list (default: male)" },
    },
}, function(a)
    local q = U.optStr(a, "query")
    local out = {}
    U.each(getAllOutfits(U.bool(a, "female", false)), function(s)
        if not q or U.contains(s, q) then out[#out + 1] = s end
    end)
    return out
end)

U.def("spawn_zombies", {
    desc = "Spawn zombies at x,y,z (server-side, synced) with an optional outfit. Ask the owner before spawning hordes near players.",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" }, { "z", "number", false, "level (default 0)" },
        { "count", "number", false, "1..100 (default 1)" },
        { "outfit", "string", false, "outfit name (see outfits); omit for random" },
        { "female_chance", "number", false, "0..100 (default 50)" },
    },
}, function(a)
    local x, y, z = U.pos(a)
    local count = U.int(a, "count", 1, 1, 100)
    local femaleChance = U.int(a, "female_chance", 50, 0, 100)
    local outfit = U.optStr(a, "outfit")
    Z.square(x, y, z)
    if outfit then
        local canon = U.findString(getAllOutfits(false), outfit) or U.findString(getAllOutfits(true), outfit)
        if not canon then error("unknown outfit '" .. outfit .. "' (see outfits)") end
        outfit = canon
    end
    local list = addZombiesInOutfit(math.floor(x), math.floor(y), z, count, outfit, femaleChance)
    local ids = {}
    U.each(list, function(zed) ids[#ids + 1] = U.try(function() return zed:getID() end) end)
    Z.event("spawn_zombies", { x = math.floor(x), y = math.floor(y), z = z, count = #ids, outfit = outfit })
    return { spawned = #ids, ids = ids, outfit = outfit, x = math.floor(x), y = math.floor(y), z = z }
end)

U.def("kill_zombies_area", {
    desc = "Kill every zombie within radius tiles of x,y,z or of a player (server-side, synced). Bodies remain.",
    authority = "server", args = {
        { "x", "number", false, "tile x (or give name)" }, { "y", "number", false, "tile y" }, { "z", "number", false, "level" },
        { "name", "string", false, "center on this player instead of x,y" },
        { "radius", "number", false, "tiles (default 10, max 80)" },
        { "killer", "string", false, "credit kills to this player (optional)" },
    },
}, function(a)
    local x, y, z, p = U.posOrPlayer(a)
    local radius = U.int(a, "radius", 10, 0, 80)
    local killer = a.killer and Z.player(tostring(a.killer)) or p
    local killed = 0
    for _, zed in ipairs(Z.zombiesNear(x, y, z, radius)) do
        local ok = pcall(function()
            if killer then zed:setAttackedBy(killer) end
            zed:Kill(killer)
        end)
        if ok then killed = killed + 1 end
    end
    Z.event("kill_zombies_area", { x = math.floor(x), y = math.floor(y), z = math.floor(z), radius = radius, killed = killed })
    return { killed = killed, x = math.floor(x), y = math.floor(y), z = math.floor(z), radius = radius }
end)

U.def("zombies_count_near", {
    desc = "Count live zombies within radius tiles of a player (or x,y,z); includes the nearest one.",
    authority = "server", args = {
        { "name", "string", false, "player (default: the single online player)" },
        { "x", "number", false, "tile x instead of a player" }, { "y", "number", false, "tile y" }, { "z", "number", false, "level" },
        { "radius", "number", false, "tiles (default 15, max 80)" },
    },
}, function(a)
    local x, y, z, p = U.posOrPlayer(a)
    local radius = U.int(a, "radius", 15, 0, 80)
    local list = Z.zombiesNear(x, y, z, radius)
    local nearest, nd = nil, nil
    local crawling, targeting = 0, 0
    for _, zed in ipairs(list) do
        local d = U.dist(zed:getX(), zed:getY(), x, y)
        if not nd or d < nd then nd, nearest = d, zed end
        if U.try(function() return zed:isCrawling() end) then crawling = crawling + 1 end
        if p and U.try(function() return zed:getTarget() == p end) then targeting = targeting + 1 end
    end
    return {
        count = #list, radius = radius, user = p and p:getUsername() or nil,
        x = U.round(x, 1), y = U.round(y, 1), z = math.floor(z),
        crawling = crawling, targetingPlayer = p and targeting or nil,
        nearest = nearest and U.zombieInfo(nearest) or nil, nearestDistance = nd and U.round(nd, 1) or nil,
    }
end)
