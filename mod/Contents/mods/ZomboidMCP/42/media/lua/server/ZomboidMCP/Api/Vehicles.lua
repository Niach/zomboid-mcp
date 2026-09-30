-- Vehicle tools: spawn_vehicle, vehicle_fix. Script search and part listings are recipes (docs/recipes/).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then if isClient and isClient() then return end error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local function partById(v, id)
    local part = U.try(function() return v:getPartById(id) end)
    if part == nil then part = U.try(function() return v:getParts():getPartById(id) end) end
    return part
end

local function partList(v)
    local parts = U.try(function() return v:getParts() end)
    local out = {}
    if not parts then return out end
    local n = U.try(function() return parts:getPartCount() end) or U.try(function() return parts:size() end) or 0
    for i = 0, n - 1 do
        local part = U.try(function() return parts:getPartByIndex(i) end) or U.try(function() return parts:get(i) end)
        if part then
            local info = { id = part:getId(), condition = U.try(function() return part:getCondition() end) }
            if U.try(function() return part:isContainer() end) then
                info.content = U.round(U.try(function() return part:getContainerContentAmount() end) or 0, 1)
                info.capacity = U.try(function() return part:getContainerCapacity() end)
            end
            out[#out + 1] = info
        end
    end
    return out
end

-- vehicle by player argument (their vehicle, else nearest within 12 tiles) or nearest to x,y,z within radius
local function findVehicle(a)
    local x, y, z, p = U.posOrPlayer(a)
    if p then
        local v = U.try(function() return p:getVehicle() end)
        if v then return v end
    end
    local radius = U.int(a, "radius", 12, 0, 40)
    local best, bd, seen = nil, nil, {}
    U.scanSquares(x, y, z, radius, function(sq)
        local v = U.try(function() return sq:getVehicleContainer() end)
        if v then
            local id = U.try(function() return v:getId() end) or tostring(v)
            if not seen[id] then
                seen[id] = true
                local d = U.dist(v:getX(), v:getY(), x, y)
                if not bd or d < bd then bd, best = d, v end
            end
        end
    end)
    if not best then
        error(string.format("no vehicle within %d tiles of %d,%d,%d", radius, math.floor(x), math.floor(y), math.floor(z)))
    end
    return best
end

Z.tool("spawn_vehicle", "Spawn a vehicle at x,y,z facing dir (addVehicleDebug; server-side, synced). Needs free flat ground; ask the owner before spawning near players.", function(a)
    local script = U.str(a, "script")
    local x, y, z = U.pos(a)
    local dirName = string.upper(U.str(a, "dir", "S"))
    local okDir = false
    for _, d in ipairs(DIRS) do if d == dirName then okDir = true end end
    if not okDir then error("dir must be one of " .. table.concat(DIRS, ", ")) end
    local vs = getScriptManager():getVehicle(script)
    if not vs then
        -- allow short names: find by suffix
        U.each(getScriptManager():getAllVehicleScripts(), function(s)
            if not vs and (U.lower(s:getFullName()) == U.lower(script) or U.lower(s:getName()) == U.lower(script)) then vs = s end
        end)
    end
    if not vs then error("unknown vehicle script '" .. script .. "' (docs/recipes/vehicle_types.md)") end
    local full = vs:getFullName()
    local sq = Z.square(x, y, z)
    local v = addVehicleDebug(full, IsoDirections[dirName], nil, sq)
    if not v then error("addVehicleDebug returned nil (square blocked or not a valid vehicle spot?)") end
    Z.event("spawn_vehicle", { script = full, x = math.floor(x), y = math.floor(y), z = z, dir = dirName })
    local info = U.vehicleInfo(v)
    info.dir = dirName
    return info
end)

Z.tool("vehicle_fix", "Repair and/or refuel a vehicle: the player's current vehicle, or the nearest to the player / to x,y,z (server-side, synced).", function(a)
    local v = findVehicle(a)
    local doRepair, doRefuel = U.bool(a, "repair", true), U.bool(a, "refuel", true)
    local before = { engineQuality = U.try(function() return v:getEngineQuality() end), parts = partList(v) }
    local res = { vehicle = U.vehicleInfo(v), repaired = false, refueled = false }
    if doRepair then
        v:repair()
        res.repaired = true
    end
    if doRefuel then
        local tank = partById(v, "GasTank")
        if not tank then
            res.refuelError = "no GasTank part"
        else
            local cap = tank:getContainerCapacity()
            tank:setContainerContentAmount(cap)
            v:transmitPartModData(tank)
            res.refueled = true
            res.fuel = { amount = cap, capacity = cap }
        end
    end
    res.before = before
    res.after = { engineQuality = U.try(function() return v:getEngineQuality() end), parts = partList(v) }
    Z.event("vehicle_fix", { id = res.vehicle.id, script = res.vehicle.script, repaired = res.repaired, refueled = res.refueled })
    return res
end)
