-- Player tools: teleport (client-authoritative) and give_item.
-- Traits, skills and appearance are scripting recipes (docs/recipes/set_traits.md, set_skills.md, set_appearance.md).
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then if isClient and isClient() then return end error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util

Z.tool("teleport", "Move a player to x,y,z. Position is client-authoritative: sends the 'teleport' command to that player's Zomboid MCP client mod (docs/PROTOCOL.md); nothing happens if the player lacks the mod. Verify with player_info.", function(a)
    local p = Z.player(U.optStr(a, "player"))
    local x, y, z = U.num(a, "x"), U.num(a, "y"), U.int(a, "z", 0, 0, 31)
    Z.toClients("teleport", { x = x, y = y, z = z }, p)
    Z.event("teleport", { user = p:getUsername(), x = x, y = y, z = z })
    return { sent = true, user = p:getUsername(), x = x, y = y, z = z,
        from = { x = U.round(p:getX(), 1), y = U.round(p:getY(), 1), z = math.floor(p:getZ()) },
        note = "applied by the client mod; verify with player_info after a second" }
end)

Z.tool("give_item", "Add items to a player's main inventory (server-side, synced with sendAddItemToContainer). Search types by scripting: docs/recipes/item_types.md.", function(a)
    local p = Z.player(U.optStr(a, "player"))
    local itemType = U.str(a, "item")
    local count = U.int(a, "count", 1, 1, 100)
    local script = getScriptManager():FindItem(itemType)
    if not script then error("unknown item type '" .. itemType .. "' (search with the item_types recipe)") end
    local full = script:getFullName()
    local inv = p:getInventory()
    local added = {}
    for _ = 1, count do
        local item = inv:AddItem(full)
        if not item then error("AddItem returned nil for " .. full) end
        sendAddItemToContainer(inv, item)
        added[#added + 1] = U.itemInfo(item)
    end
    Z.event("give_item", { user = p:getUsername(), type = full, count = count })
    return { user = p:getUsername(), type = full, count = #added, name = script:getDisplayName(), items = added }
end)
