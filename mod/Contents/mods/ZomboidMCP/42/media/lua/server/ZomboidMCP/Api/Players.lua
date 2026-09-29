-- Player tools: teleport (client), set_traits, set_skills, set_appearance, give_item, plus lookup helpers.
require "ZomboidMCP/Bridge"
require "ZomboidMCP/Api/Common"

local Z = ZMCP
local U = Z.util

---------------------------------------------------------------- teleport (client-authoritative)
U.def("teleport", {
    desc = "Move a player to x,y,z. Position is client-authoritative: sends the 'teleport' command to that player's Zomboid MCP client mod (see docs/PROTOCOL.md); nothing happens if the player lacks the mod.",
    authority = "client", args = {
        { "name", "string", false, "player (optional when one player is online)" },
        { "x", "number", true, "target tile x" }, { "y", "number", true, "target tile y" }, { "z", "number", false, "level (default 0)" },
    },
}, function(a)
    local p = Z.player(U.optStr(a, "name"))
    local x, y, z = U.num(a, "x"), U.num(a, "y"), U.int(a, "z", 0, 0, 31)
    Z.toClients("teleport", { x = x, y = y, z = z }, p)
    Z.event("teleport", { user = p:getUsername(), x = x, y = y, z = z })
    return { sent = true, user = p:getUsername(), x = x, y = y, z = z,
        from = { x = U.round(p:getX(), 1), y = U.round(p:getY(), 1), z = math.floor(p:getZ()) },
        note = "applied by the client mod; verify with player_info after a second" }
end)

---------------------------------------------------------------- traits
local function traitKey(name)
    local k = string.upper(tostring(name))
    k = string.gsub(k, "[^%w]", "_")
    return k
end

-- resolve a trait by constant name (BRAVE / brave / Fast Learner), id (base:brave) or label
local function findTrait(name)
    local t = U.try(function() return CharacterTrait[traitKey(name)] end)
    if t then return t end
    local w = U.lower(name)
    local defs = U.try(function() return CharacterTraitDefinition.getTraits() end)
    if defs then
        for i = 0, defs:size() - 1 do
            local d = defs:get(i)
            local ty = d:getType()
            local id = U.lower(U.try(function() return ty:getName() end))
            local label = U.lower(U.try(function() return d:getLabel() end))
            local short = string.match(id, ":(.*)$") or id
            if id == w or short == w or label == w then return ty end
        end
    end
    error("unknown trait '" .. tostring(name) .. "' (use traits_list to search)")
end
Z.findTrait = findTrait

U.def("traits_list", {
    desc = "Search available character traits (id, label, cost). Empty query lists all.",
    authority = "server", args = { { "query", "string", false, "substring of id or label" } },
}, function(a)
    local q = U.optStr(a, "query")
    local out = {}
    local defs = CharacterTraitDefinition.getTraits()
    for i = 0, defs:size() - 1 do
        local d = defs:get(i)
        local id = tostring(U.try(function() return d:getType():getName() end))
        local label = U.try(function() return d:getLabel() end) or ""
        if not q or U.contains(id, q) or U.contains(label, q) then
            out[#out + 1] = { id = id, label = label, cost = U.try(function() return d:getCost() end),
                free = U.try(function() return d:isFree() end) }
        end
    end
    return out
end)

U.def("set_traits", {
    desc = "Add and/or remove traits on a player (server-side, synced; the client UI may only refresh after relog).",
    authority = "server", args = {
        { "name", "string", false, "player" },
        { "add", "string[]", false, "traits to add, e.g. [\"Brave\", \"FAST_LEARNER\"]" },
        { "remove", "string[]", false, "traits to remove" },
    },
}, function(a)
    local p = Z.player(U.optStr(a, "name"))
    local traits = p:getCharacterTraits()
    local added, removed = {}, {}
    for _, n in ipairs(U.tbl(a, "add", {})) do
        local t = findTrait(n)
        traits:add(t); added[#added + 1] = tostring(t:getName())
    end
    for _, n in ipairs(U.tbl(a, "remove", {})) do
        local t = findTrait(n)
        traits:remove(t); removed[#removed + 1] = tostring(t:getName())
    end
    pcall(sendPlayerExtraInfo, p)
    Z.event("set_traits", { user = p:getUsername(), add = added, remove = removed })
    return { user = p:getUsername(), added = added, removed = removed, traits = Z.traitsOf(p) }
end)

---------------------------------------------------------------- skills
local function findPerk(name)
    local perk = U.try(function() return Perks[name] end)
    if perk then return perk end
    local w = U.lower(name)
    local found
    U.each(PerkFactory.PerkList, function(pk)
        if not found and (U.lower(pk:getId()) == w or U.lower(U.try(function() return PerkFactory.getPerkName(pk) end)) == w) then found = pk end
    end)
    if not found then error("unknown skill '" .. tostring(name) .. "' (ids: see player_info skills, e.g. Woodwork, Aiming, Fitness)") end
    return found
end
Z.findPerk = findPerk

U.def("set_skills", {
    desc = "Set skill levels {Perk = level 0..10}. Raising a level grants XP through the synced addXpNoMultiplier path; lowering sets the level directly on the server copy (client may need a relog).",
    authority = "server", args = {
        { "name", "string", false, "player" },
        { "skills", "object", true, "map of perk id -> level, e.g. {\"Woodwork\": 5, \"Aiming\": 10}" },
    },
}, function(a)
    local p = Z.player(U.optStr(a, "name"))
    local out = {}
    for pname, lvl in pairs(U.tbl(a, "skills")) do
        local perk = findPerk(pname)
        local target = tonumber(lvl)
        if not target or target < 0 or target > 10 then error("level for " .. tostring(pname) .. " must be 0..10") end
        target = math.floor(target)
        local cur = p:getPerkLevel(perk)
        local how
        if target > cur then
            local have = p:getXp():getXP(perk)
            local need = perk:getTotalXpForLevel(target) - have
            if need > 0 then addXpNoMultiplier(p, perk, need) end
            how = "xp"
        elseif target < cur then
            p:setPerkLevelDebug(perk, target)
            p:getXp():setXPToLevel(perk, target)
            how = "direct"
        else
            how = "unchanged"
        end
        out[#out + 1] = { id = perk:getId(), before = cur, after = p:getPerkLevel(perk), requested = target, method = how }
    end
    Z.event("set_skills", { user = p:getUsername(), skills = out })
    return { user = p:getUsername(), changes = out }
end)

---------------------------------------------------------------- appearance
local function parseColor(v)
    if v == nil or v == "" then return nil end
    if type(v) == "table" then
        return ImmutableColor.new(tonumber(v[1] or v.r) or 0, tonumber(v[2] or v.g) or 0, tonumber(v[3] or v.b) or 0)
    end
    v = tostring(v)
    local hex = string.match(v, "^#?(%x%x%x%x%x%x)$")
    if hex then
        return ImmutableColor.new(tonumber(string.sub(hex, 1, 2), 16) / 255, tonumber(string.sub(hex, 3, 4), 16) / 255, tonumber(string.sub(hex, 5, 6), 16) / 255)
    end
    local r, g, b = string.match(v, "^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
    if r then
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
        return ImmutableColor.new(r, g, b)
    end
    error("color must be '#rrggbb' or 'r,g,b' (0..1 or 0..255), got " .. v)
end

U.def("hair_styles", {
    desc = "List hair and beard style ids (for set_appearance).",
    authority = "server", args = { { "female", "boolean", false, "female hair list (default: male)" } },
}, function(a)
    return {
        hair = U.toList(getAllHairStyles(U.bool(a, "female", false))),
        beard = U.toList(getAllBeardStyles()),
    }
end)

U.def("set_appearance", {
    desc = "Change hair/beard model and hair/beard/skin colors. Applied on the server copy and broadcast with sendHumanVisual, and also sent to the owning client as the 'appearance' command (client-authoritative fallback, docs/PROTOCOL.md).",
    authority = "mixed", args = {
        { "name", "string", false, "player" },
        { "hair", "string", false, "hair style id (hair_styles)" }, { "beard", "string", false, "beard style id ('' for none)" },
        { "hair_color", "string", false, "'#rrggbb' or 'r,g,b'" }, { "beard_color", "string", false, "'#rrggbb' or 'r,g,b'" },
        { "skin_color", "string", false, "'#rrggbb' or 'r,g,b'" },
    },
}, function(a)
    local p = Z.player(U.optStr(a, "name"))
    local vis = p:getHumanVisual()
    local applied, msg = {}, {}
    local hair = a.hair
    if hair ~= nil then
        hair = tostring(hair)
        local canon = U.findString(getAllHairStyles(p:isFemale()), hair)
        if not canon and hair ~= "" then error("unknown hair style '" .. hair .. "' (see hair_styles)") end
        vis:setHairModel(canon or ""); applied.hair = canon or ""; msg.hair = canon or ""
    end
    local beard = a.beard
    if beard ~= nil then
        beard = tostring(beard)
        local canon = U.findString(getAllBeardStyles(), beard)
        if not canon and beard ~= "" then error("unknown beard style '" .. beard .. "' (see hair_styles)") end
        vis:setBeardModel(canon or ""); applied.beard = canon or ""; msg.beard = canon or ""
    end
    local hc = parseColor(a.hair_color)
    if hc then vis:setHairColor(hc); applied.hair_color = tostring(a.hair_color); msg.hair_color = tostring(a.hair_color) end
    local bc = parseColor(a.beard_color)
    if bc then vis:setBeardColor(bc); applied.beard_color = tostring(a.beard_color); msg.beard_color = tostring(a.beard_color) end
    local sc = parseColor(a.skin_color)
    if sc then vis:setSkinColor(sc); applied.skin_color = tostring(a.skin_color); msg.skin_color = tostring(a.skin_color) end
    pcall(function() p:resetModelNextFrame() end)
    pcall(sendHumanVisual, p)
    Z.toClients("appearance", msg, p)
    Z.event("set_appearance", { user = p:getUsername(), applied = applied })
    return { user = p:getUsername(), applied = applied,
        current = { hair = vis:getHairModel(), beard = vis:getBeardModel() } }
end)

---------------------------------------------------------------- items
U.def("give_item", {
    desc = "Add items to a player's main inventory (server-side, synced with sendAddItemToContainer).",
    authority = "server", args = {
        { "name", "string", false, "player" },
        { "type", "string", true, "full item type, e.g. Base.Axe (see item_types)" },
        { "count", "number", false, "1..100 (default 1)" },
    },
}, function(a)
    local p = Z.player(U.optStr(a, "name"))
    local itemType = U.str(a, "type")
    local count = U.int(a, "count", 1, 1, 100)
    local script = getScriptManager():FindItem(itemType)
    if not script then error("unknown item type '" .. itemType .. "' (use item_types to search)") end
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
