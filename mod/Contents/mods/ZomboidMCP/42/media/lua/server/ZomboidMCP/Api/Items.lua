-- Item tools: spawn_item on the ground. Searching item scripts is a recipe (docs/recipes/item_types.md).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.def) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

U.def("spawn_item", {
    desc = "Drop items on the ground at x,y,z (server-side, synced). scatter spreads them over a radius of tiles. Only loaded squares (near players).",
    authority = "server", args = {
        { "x", "number", true, "tile x" }, { "y", "number", true, "tile y" }, { "z", "number", false, "level (default 0)" },
        { "type", "string", true, "full item type, e.g. Base.Banana" },
        { "count", "number", false, "1..200 (default 1)" },
        { "scatter", "number", false, "radius in tiles to spread items over (default 0, max 20)" },
    },
}, function(a)
    local x, y, z = U.pos(a)
    local itemType = U.str(a, "type")
    local count = U.int(a, "count", 1, 1, 200)
    local scatter = U.int(a, "scatter", 0, 0, 20)
    local script = getScriptManager():FindItem(itemType)
    if not script then error("unknown item type '" .. itemType .. "' (search with the item_types recipe)") end
    local full = script:getFullName()
    local center = Z.square(x, y, z)
    local cell = getCell()
    local placed, skipped, squares = 0, 0, {}
    for _ = 1, count do
        local sq = center
        if scatter > 0 then
            sq = cell:getGridSquare(x + ZombRand(-scatter, scatter + 1), y + ZombRand(-scatter, scatter + 1), z)
        end
        local item = sq and sq:AddWorldInventoryItem(full, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
        if item then
            placed = placed + 1
            local key = sq:getX() .. "," .. sq:getY()
            squares[key] = (squares[key] or 0) + 1
        else
            skipped = skipped + 1
        end
    end
    Z.event("spawn_item", { type = full, count = placed, x = x, y = y, z = z })
    return { type = full, name = script:getDisplayName(), placed = placed, skipped = skipped, squares = squares }
end)
