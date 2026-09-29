-- Object tools: place_object, remove_object, sprite_search, build_structure.
-- Tiles are IsoObjects with a sprite name like "walls_exterior_wooden_01_2" (see Api/TileSheets.lua for the sheets).
require "ZomboidMCP/Bridge"
require "ZomboidMCP/Api/Common"
require "ZomboidMCP/Api/TileSheets"

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
    if live == false then error("unknown sprite '" .. name .. "' (use sprite_search)") end
    if spriteExistsIndex(name) then return "index" end
    error("unknown sprite '" .. name .. "' (not in the vanilla tilesheet index; use sprite_search)")
end
Z.checkSprite = checkSprite

U.def("sprite_search", {
    desc = "Search tile sprite names (e.g. 'walls_exterior_wooden', 'furniture_seating_indoor'). Uses the live sprite map (mods included) or the vanilla tilesheet index. Also returns matching sheets with their tile counts: a sheet 'X' with count N has sprites X_0 .. X_(N-1).",
    authority = "server", args = {
        { "query", "string", true, "substring of the sprite/sheet name" },
        { "limit", "number", false, "max sprite names (default 100, max 2000)" },
    },
}, function(a)
    local q = U.str(a, "query")
    local limit = U.int(a, "limit", 100, 1, 2000)
    local sheets = {}
    for sheet, count in pairs(Z.tileSheets) do
        if U.contains(sheet, q) then sheets[#sheets + 1] = { sheet = sheet, count = count } end
    end
    table.sort(sheets, function(x, y) return x.sheet < y.sheet end)

    local names, total, source = {}, 0, "index"
    local map = spriteMap()
    local live = map and U.try(function() return transformIntoKahluaTable(map) end)
    if live then
        source = "live"
        for name in pairs(live) do
            if type(name) == "string" and U.contains(name, q) then
                total = total + 1
                names[#names + 1] = name
            end
        end
        table.sort(names)
        while #names > limit do table.remove(names) end
    else
        for _, s in ipairs(sheets) do
            for i = 0, s.count - 1 do
                total = total + 1
                if #names < limit then names[#names + 1] = s.sheet .. "_" .. i end
            end
        end
    end
    return { query = q, source = source, sheets = sheets, sprites = names, total = total, truncated = total > #names }
end)

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

U.def("place_object", {
    desc = "Place a tile object (any vanilla/mod sprite) on a loaded square: IsoObject.new + transmitAddObjectToSquare (server-side, synced). Ask the owner before building near players.",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" }, { "z", "number", false, "level (default 0)" },
        { "sprite", "string", true, "sprite name, e.g. walls_exterior_wooden_01_2 (see sprite_search)" },
        { "name", "string", false, "object name (optional, e.g. 'Campfire')" },
    },
}, function(a)
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

U.def("remove_object", {
    desc = "Remove a tile object from a square by sprite name or object index (transmitRemoveItemFromSquare; server-side, synced). Without sprite/index it just lists the square's objects. Floors need force=true.",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" }, { "z", "number", false, "level (default 0)" },
        { "sprite", "string", false, "sprite name to remove (first match)" },
        { "index", "number", false, "object index on the square (from world_query/remove_object listing)" },
        { "all", "boolean", false, "remove every object matching sprite (default false)" },
        { "force", "boolean", false, "allow removing the floor (default false)" },
    },
}, function(a)
    local x, y, z = U.pos(a)
    local sq = Z.square(x, y, z)
    local sprite, index = U.optStr(a, "sprite"), a.index
    if not sprite and index == nil then
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
        U.each(sq:getObjects(), function(o)
            local n = U.try(function() return o:getSprite() and o:getSprite():getName() end) or U.try(function() return o:getSpriteName() end)
            if n == sprite and (all or #targets == 0) then targets[#targets + 1] = o end
        end)
        if #targets == 0 then error("no object with sprite '" .. sprite .. "' on " .. sq:getX() .. "," .. sq:getY() .. "," .. z) end
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

U.def("build_structure", {
    desc = "Place many tile objects in one call: objects = [{x, y, z, sprite, name?}, ...] (max 500). Per-entry errors are collected, the rest is still placed. Ask the owner before building near players.",
    authority = "server", args = {
        { "objects", "object[]", true, "list of {x, y, z?, sprite, name?}" },
        { "stop_on_error", "boolean", false, "abort at the first failing entry (default false)" },
    },
}, function(a)
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
