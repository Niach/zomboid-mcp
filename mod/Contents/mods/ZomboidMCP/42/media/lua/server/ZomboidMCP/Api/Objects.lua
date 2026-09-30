-- Object tools: place_object, remove_object, build_structure. Sprite search is a recipe (docs/recipes/sprite_search.md).
-- Tiles are IsoObjects with a sprite name like "walls_exterior_wooden_01_2" (see Api/TileSheets.lua for the sheets).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then if isClient and isClient() then return end error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end
if not (ZMCP and ZMCP.tileSheets) then pcall(require, "ZomboidMCP/Api/TileSheets") end
if not (ZMCP and ZMCP.tileSheets) then error("ZomboidMCP/Api/TileSheets.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

---------------------------------------------------------------- sprite lookup
-- the live named sprite map (HashMap<String, IsoSprite>) if reachable from Lua
local function spriteMap()
    return U.try(function() return IsoSpriteManager.instance:getNamedMap() end)
end

-- true/false when known, nil when the live map is unavailable
local function spriteExistsLive(name)
    local map = spriteMap()
    if not map then return nil end
    local ok, v = pcall(function() return map:containsKey(name) end)
    if ok then return v and true or false end
    return nil
end

local function spriteExistsIndex(name)
    local sheet, n = string.match(name, "^(.-)_(%d+)$")
    if not sheet then return false end
    local count = Z.tileSheets[sheet]
    return count ~= nil and tonumber(n) < count
end

-- validate a sprite name; errors with a hint. Never calls getSprite(name) since that creates blank sprites.
local function checkSprite(name)
    local live = spriteExistsLive(name)
    if live == true then return "live" end
    if live == false then error("unknown sprite '" .. name .. "' (docs/recipes/sprite_search.md)") end
    if spriteExistsIndex(name) then return "index" end
    error("unknown sprite '" .. name .. "' (not in the vanilla tilesheet index; docs/recipes/sprite_search.md)")
end
Z.checkSprite = checkSprite

---------------------------------------------------------------- place / remove
local function placeOne(x, y, z, sprite, name)
    local sq = Z.square(x, y, z)
    local how = checkSprite(sprite)
    local obj
    if name and name ~= "" then obj = IsoObject.new(sq, sprite, name) else obj = IsoObject.new(sq, sprite) end
    sq:transmitAddObjectToSquare(obj, -1)
    return { x = sq:getX(), y = sq:getY(), z = sq:getZ(), sprite = sprite, name = name,
        index = U.try(function() return obj:getObjectIndex() end), spriteSource = how }
end

Z.tool("place_object", "Place a tile object (any vanilla/mod sprite) on a loaded square: IsoObject.new + transmitAddObjectToSquare (server-side, synced). Ask the owner before building near players.", function(a)
    local x, y, z = U.pos(a)
    local res = placeOne(x, y, z, U.str(a, "sprite"), U.optStr(a, "name"))
    Z.event("place_object", res)
    return res
end)

local function listObjects(sq)
    local floor = sq:getFloor()
    local out = {}
    U.each(sq:getObjects(), function(o, i)
        local info = U.objectInfo(o, i)
        info.floor = (o == floor)
        out[#out + 1] = info
    end)
    return out
end

Z.tool("remove_object", "Remove a tile object from a square by sprite name, object name or object index (transmitRemoveItemFromSquare; server-side, synced). Without sprite/name/index it just lists the square's objects (each with sprite, type, name, index). Floors need force=true.", function(a)
    local x, y, z = U.pos(a)
    local sq = Z.square(x, y, z)
    local sprite, objName, index = U.optStr(a, "sprite"), U.optStr(a, "name"), a.index
    if not sprite and not objName and index == nil then
        return { x = sq:getX(), y = sq:getY(), z = z, objects = listObjects(sq), removed = {} }
    end
    local force, all = U.bool(a, "force", false), U.bool(a, "all", false)
    local floor = sq:getFloor()
    local targets = {}
    if index ~= nil then
        index = U.int(a, "index", nil, 0, 10000)
        local objs = sq:getObjects()
        if index >= objs:size() then error("index " .. index .. " out of range (square has " .. objs:size() .. " objects)") end
        targets[1] = objs:get(index)
    else
        -- sprite and/or name: both must match when both are given (first match, or every match with `all`)
        U.each(sq:getObjects(), function(o)
            local spriteOk = not sprite or U.spriteName(o) == sprite
            local nameOk = not objName or U.try(function() return o:getName() end) == objName
            if spriteOk and nameOk and (all or #targets == 0) then targets[#targets + 1] = o end
        end)
        if #targets == 0 then
            local what = sprite and ("sprite '" .. sprite .. "'") or ""
            if objName then what = what .. (sprite and " and " or "") .. "name '" .. objName .. "'" end
            error("no object with " .. what .. " on " .. sq:getX() .. "," .. sq:getY() .. "," .. z .. " (call without sprite/name/index to list the square)")
        end
    end
    local removed = {}
    for _, o in ipairs(targets) do
        if o == floor and not force then error("refusing to remove the floor tile (pass force=true)") end
        local info = U.objectInfo(o, U.try(function() return o:getObjectIndex() end))
        sq:transmitRemoveItemFromSquare(o)
        removed[#removed + 1] = info
    end
    Z.event("remove_object", { x = sq:getX(), y = sq:getY(), z = z, removed = #removed })
    return { x = sq:getX(), y = sq:getY(), z = z, removed = removed, objects = listObjects(sq) }
end)

Z.tool("build_structure", "Place many tile objects in one call: objects = [{x, y, z, sprite, name?}, ...] (max 500). Per-entry errors are collected, the rest is still placed. Ask the owner before building near players.", function(a)
    local list = U.tbl(a, "objects")
    if #list == 0 then error("objects must be a non-empty list") end
    if #list > 500 then error("max 500 objects per call") end
    local stop = U.bool(a, "stop_on_error", false)
    local placed, errors = {}, {}
    for i, o in ipairs(list) do
        if type(o) ~= "table" then
            errors[#errors + 1] = { i = i, error = "entry is not an object" }
        else
            local ok, res = pcall(function()
                local x, y, z = U.pos(o)
                return placeOne(x, y, z, U.str(o, "sprite"), U.optStr(o, "name"))
            end)
            if ok then placed[#placed + 1] = res
            else
                errors[#errors + 1] = { i = i, error = tostring(res), x = o.x, y = o.y, z = o.z, sprite = o.sprite }
                if stop then break end
            end
        end
    end
    Z.event("build_structure", { placed = #placed, errors = #errors })
    return { placed = #placed, errors = errors, objects = placed }
end)
