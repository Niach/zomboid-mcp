-- Zombie tools: spawn_zombies, kill_zombies_area. Outfit lists and counts are recipes (docs/recipes/).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

Z.tool("spawn_zombies", "Spawn zombies at x,y,z (server-side, synced) with an optional outfit (names: docs/recipes/outfits.md). Ask the owner before spawning hordes near players.", function(a)
    local x, y, z = U.pos(a)
    local count = U.int(a, "count", 1, 1, 100)
    local femaleChance = U.int(a, "female_chance", 50, 0, 100)
    local outfit = U.optStr(a, "outfit")
    Z.square(x, y, z)
    if outfit then
        local canon = U.findString(getAllOutfits(false), outfit) or U.findString(getAllOutfits(true), outfit)
        if not canon then error("unknown outfit '" .. outfit .. "' (list them with the outfits recipe)") end
        outfit = canon
    end
    local list = addZombiesInOutfit(x, y, z, count, outfit, femaleChance)
    local ids = {}
    U.each(list, function(zed) ids[#ids + 1] = U.try(function() return zed:getID() end) end)
    Z.event("spawn_zombies", { x = x, y = y, z = z, count = #ids, outfit = outfit })
    return { spawned = #ids, ids = ids, outfit = outfit, x = x, y = y, z = z }
end)

Z.tool("kill_zombies_area", "Kill every zombie within radius tiles of x,y,z or of a player (server-side, synced). Bodies remain.", function(a)
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
