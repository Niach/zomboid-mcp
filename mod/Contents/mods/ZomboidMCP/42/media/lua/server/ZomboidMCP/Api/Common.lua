-- Shared helpers for the Zomboid MCP tool modules (Api/*.lua): argument validation, Java list iteration,
-- item/object/player summaries and square scans. Server only. Re-runnable (hot reload).
-- Tools register with ZMCP.tool(name, desc, fn); argument schemas live in the MCP catalogue (mcp/zmcp_catalog.py).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then if isClient and isClient() then return end error("ZomboidMCP/Bridge.lua must be loaded before Api/") end

local Z = ZMCP
Z.util = Z.util or {}
local U = Z.util

---------------------------------------------------------------- argument validation
local function lower(s) return string.lower(tostring(s or "")) end
U.lower = lower

function U.num(a, key, default, min, max)
    local v = a[key]
    if v == nil or v == "" then
        if default == nil then error("argument '" .. key .. "' (number) is required") end
        v = default
    end
    if type(v) == "string" then v = tonumber(v) end
    if type(v) ~= "number" then error("argument '" .. key .. "' must be a number") end
    if min and v < min then error(string.format("argument '%s' must be >= %s", key, tostring(min))) end
    if max and v > max then error(string.format("argument '%s' must be <= %s", key, tostring(max))) end
    return v
end

function U.int(a, key, default, min, max)
    local v = U.num(a, key, default, min, max)
    return math.floor(v)
end

function U.str(a, key, default)
    local v = a[key]
    if v == nil or v == "" then
        if default == nil then error("argument '" .. key .. "' (string) is required") end
        return default
    end
    if type(v) ~= "string" then v = tostring(v) end
    return v
end

function U.optStr(a, key)
    local v = a[key]
    if v == nil or v == "" then return nil end
    return tostring(v)
end

function U.bool(a, key, default)
    local v = a[key]
    if v == nil then return default end
    if type(v) == "string" then return v == "true" or v == "1" or v == "yes" end
    return v and true or false
end

function U.tbl(a, key, default)
    local v = a[key]
    if v == nil then
        if default == nil then error("argument '" .. key .. "' (list/object) is required") end
        return default
    end
    if type(v) ~= "table" then error("argument '" .. key .. "' must be a list/object") end
    return v
end

-- tile x, y, z from args (floored; z defaults to 0); errors if x or y missing
function U.pos(a)
    return U.int(a, "x"), U.int(a, "y"), U.int(a, "z", 0, 0, 31)
end

-- position from either a player (username) or x,y,z. Returns x, y, z, player|nil
function U.posOrPlayer(a)
    local name = U.optStr(a, "player")
    if name or (a.x == nil and a.y == nil) then
        local p = Z.player(name)
        return p:getX(), p:getY(), p:getZ(), p
    end
    local x, y, z = U.pos(a)
    return x, y, z, nil
end

function U.oneOf(a, key, options, default)
    local v = lower(U.str(a, key, default))
    for _, o in ipairs(options) do if v == o then return v end end
    error("argument '" .. key .. "' must be one of: " .. table.concat(options, ", "))
end

---------------------------------------------------------------- java helpers
-- iterate a Java List (ArrayList / PZArrayList): fn(element, index0)
function U.each(list, fn)
    if not list then return end
    local n = list:size()
    for i = 0, n - 1 do fn(list:get(i), i) end
end

function U.toList(list, map)
    local out = {}
    U.each(list, function(e, i) out[#out + 1] = map and map(e, i) or e end)
    return out
end

-- pcall a getter chain; nil on error
function U.try(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

function U.round(v, digits)
    if type(v) ~= "number" then return v end
    local m = 10 ^ (digits or 2)
    return math.floor(v * m + 0.5) / m
end

function U.dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- find in a Java ArrayList<String> case-insensitively; returns the canonical entry or nil
function U.findString(list, wanted)
    local w = lower(wanted)
    local found
    U.each(list, function(s) if not found and lower(s) == w then found = s end end)
    return found
end

function U.contains(text, query)
    return string.find(lower(text), lower(query), 1, true) ~= nil
end

---------------------------------------------------------------- summaries
function U.itemInfo(item)
    if not item then return nil end
    return {
        type = U.try(function() return item:getFullType() end) or item:getType(),
        name = U.try(function() return item:getDisplayName() end) or item:getName(),
        category = U.try(function() return item:getDisplayCategory() end),
        condition = U.try(function() return item:getCondition() end),
        conditionMax = U.try(function() return item:getConditionMax() end),
        weight = U.round(U.try(function() return item:getActualWeight() end) or 0, 2),
        id = U.try(function() return item:getID() end),
    }
end

function U.playerSummary(p)
    return {
        user = p:getUsername(), name = Z.charName(p),
        x = U.round(p:getX(), 2), y = U.round(p:getY(), 2), z = math.floor(p:getZ()),
        dead = p:isDead(),
        health = U.round(U.try(function() return p:getBodyDamage():getOverallBodyHealth() end) or 0, 1),
        accessLevel = U.try(function() return p:getAccessLevel() end),
        onlineId = U.try(function() return p:getOnlineID() end),
        inVehicle = U.try(function() local v = p:getVehicle(); return v and v:getScriptName() or nil end),
    }
end

-- the sprite name of a tile object, trying every accessor 42.21 offers (a placed IsoObject answered nil to the
-- first one on the live server, ZOM-17): IsoObject:getSpriteName(), IsoSprite:getName(), the sprite's parent object
-- name, and the texture name as a last resort. nil when nothing answers.
function U.spriteName(o)
    local function nonEmpty(v) if type(v) == "string" and v ~= "" then return v end return nil end
    return nonEmpty(U.try(function() return o:getSpriteName() end))
        or nonEmpty(U.try(function() local sp = o:getSprite(); return sp and sp:getName() end))
        or nonEmpty(U.try(function() local sp = o:getSprite(); return sp and sp:getParentObjectName() end))
        or nonEmpty(U.try(function() return o:getTextureName() end))
end

function U.objectInfo(o, index)
    return {
        index = index,
        sprite = U.spriteName(o),
        type = U.try(function() return o:getObjectName() end),
        name = U.try(function() local n = o:getName(); if n ~= "" then return n end return nil end),
    }
end

function U.zombieInfo(zed)
    local target = U.try(function()
        local t = zed:getTarget()
        if t and instanceof(t, "IsoPlayer") then return t:getUsername() end
        return nil
    end)
    return {
        id = U.try(function() return zed:getID() end),
        x = U.round(zed:getX(), 2), y = U.round(zed:getY(), 2), z = math.floor(zed:getZ()),
        outfit = U.try(function() return zed:getOutfitName() end),
        crawling = U.try(function() return zed:isCrawling() end),
        female = U.try(function() return zed:isFemale() end),
        health = U.round(U.try(function() return zed:getHealth() end) or 0, 2),
        target = target,
    }
end

function U.vehicleInfo(v)
    return {
        id = U.try(function() return v:getId() end),
        script = U.try(function() return v:getScriptName() end),
        x = U.round(v:getX(), 2), y = U.round(v:getY(), 2), z = math.floor(v:getZ()),
        speed = U.round(U.try(function() return v:getCurrentSpeedKmHour() end) or 0, 1),
        engineRunning = U.try(function() return v:isEngineRunning() end),
        engineQuality = U.try(function() return v:getEngineQuality() end),
        driver = U.try(function()
            local d = v:getDriver()
            return d and instanceof(d, "IsoPlayer") and d:getUsername() or nil
        end),
    }
end

-- scan loaded squares in a (2r+1)^2 area around x,y at level z: fn(square, dx, dy); returns number of unloaded squares
function U.scanSquares(x, y, z, radius, fn)
    local cell = getCell()
    local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z or 0)
    local missing = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(fx + dx, fy + dy, fz)
            if sq then fn(sq, dx, dy) else missing = missing + 1 end
        end
    end
    return missing
end
