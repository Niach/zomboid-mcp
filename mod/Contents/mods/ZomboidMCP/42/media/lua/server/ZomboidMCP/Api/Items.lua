-- Item tools: spawn_item on the ground, item_types search.
require "ZomboidMCP/Bridge"
require "ZomboidMCP/Api/Common"

local Z = ZMCP
local U = Z.util

U.def("item_types", {
    desc = "Search item scripts by type or display name (getScriptManager). Returns full types usable with give_item/spawn_item.",
    authority = "server", args = {
        { "query", "string", true, "substring, e.g. 'banana' or 'Base.Axe'" },
        { "limit", "number", false, "max results (default 50, max 500)" },
        { "include_hidden", "boolean", false, "include hidden/obsolete scripts (default false)" },
    },
}, function(a)
    local q = U.str(a, "query")
    local limit = U.int(a, "limit", 50, 1, 500)
    local hidden = U.bool(a, "include_hidden", false)
    local out, total = {}, 0
    U.each(getScriptManager():getAllItems(), function(s)
        local full = s:getFullName()
        local disp = U.try(function() return s:getDisplayName() end) or ""
        if U.contains(full, q) or U.contains(disp, q) then
            local isHidden = U.try(function() return s:isHidden() end) or U.try(function() return s:getObsolete() end)
            if hidden or not isHidden then
                total = total + 1
                if #out < limit then
                    out[#out + 1] = { type = full, name = disp,
                        category = U.try(function() return s:getDisplayCategory() end),
                        weight = U.round(U.try(function() return s:getActualWeight() end) or 0, 2) }
                end
            end
        end
    end)
    return { query = q, total = total, items = out, truncated = total > #out }
end)

U.def("spawn_item", {
    desc = "Drop items on the ground at x,y,z (server-side, synced). scatter spreads them over a radius of tiles.",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" }, { "z", "number", false, "level (default 0)" },
        { "type", "string", true, "full item type, e.g. Base.Banana (see item_types)" },
        { "count", "number", false, "1..200 (default 1)" },
        { "scatter", "number", false, "radius in tiles to spread items over (default 0, max 20)" },
    },
}, function(a)
    local x, y, z = U.pos(a)
    local itemType = U.str(a, "type")
    local count = U.int(a, "count", 1, 1, 200)
    local scatter = U.int(a, "scatter", 0, 0, 20)
    local script = getScriptManager():FindItem(itemType)
    if not script then error("unknown item type '" .. itemType .. "' (use item_types to search)") end
    local full = script:getFullName()
    local center = Z.square(x, y, z)
    local cell = getCell()
    local placed, skipped, squares = 0, 0, {}
    for _ = 1, count do
        local sq = center
        if scatter > 0 then
            local dx = ZombRand(-scatter, scatter + 1)
            local dy = ZombRand(-scatter, scatter + 1)
            sq = cell:getGridSquare(math.floor(x) + dx, math.floor(y) + dy, z)
        end
        if sq then
            local item = sq:AddWorldInventoryItem(full, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
            if item then
                placed = placed + 1
                local key = sq:getX() .. "," .. sq:getY()
                squares[key] = (squares[key] or 0) + 1
            else
                skipped = skipped + 1
            end
        else
            skipped = skipped + 1
        end
    end
    Z.event("spawn_item", { type = full, count = placed, x = math.floor(x), y = math.floor(y), z = z })
    return { type = full, name = script:getDisplayName(), placed = placed, skipped = skipped, squares = squares }
end)
