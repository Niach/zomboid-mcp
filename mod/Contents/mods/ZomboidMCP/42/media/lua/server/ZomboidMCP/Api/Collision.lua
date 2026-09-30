-- Collision tools: collision_place, collision_list, collision_clear (server side). Invisible blocking world
-- objects for custom 3D models: an IsoObject named "ZMCP_collision" whose sprite ("zmcp_collision_<kind>",
-- shared/ZomboidMCP/CollisionSprites.lua, registered on the server and on every client) carries the vanilla
-- solid / solidtrans / WallN / WallW flags, so players, zombies and line of sight treat it like a real wall or a
-- solid object. Server-authoritative: IsoObject.new + transmitAddObjectToSquare (same path as place_object), the
-- object lives in the chunk save like any placed tile. AddTileObject recalculates the square's collide matrix
-- and notifies the zombie path map (PolygonalMap2.squareChanged) at once.
-- Registry (small): ModData "ZomboidMCP".collision["x,y,z:kind"] = {x, y, z, kind, name, t}. The objects themselves are
-- the source of truth (collision_list reconciles: an entry whose loaded square has no blocker any more is dropped,
-- so remove_object works on them too). Model placements use Z.collision.placeOne (model_place {collide = true}).
if isClient() then return end
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then if isClient and isClient() then return end error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end
if not ZMCPCollision then pcall(require, "ZomboidMCP/CollisionSprites") end
if not ZMCPCollision then error("ZomboidMCP/CollisionSprites.lua (shared) must be loaded first") end

local Z = ZMCP
local U = Z.util
local J = ZMCPJson
local CS = ZMCPCollision
Z.collision = Z.collision or {}
local K = Z.collision
K.version = "0.1.0"
K.MAX_SQUARES = 2500            -- per call (a 50x50 rectangle)

local function arr(t) if J.array then return J.array(t) end return t end

local function store()
    local s = ModData.getOrCreate("ZomboidMCP")
    if type(s.collision) ~= "table" then s.collision = {} end
    return s.collision
end
K.store = store

local function key(x, y, z, kind) return x .. "," .. y .. "," .. z .. ":" .. kind end

local function checkKind(kind, allowRemove)
    kind = string.lower(tostring(kind or ""))
    if CS.KINDS[kind] then return kind end
    if allowRemove and kind == "remove" then return kind end
    local opts = table.concat(CS.ORDER, "|")
    error("kind must be " .. opts .. (allowRemove and "|remove" or "") .. " (got '" .. kind .. "')")
end
K.checkKind = checkKind

local function spriteNameOf(o)
    return U.try(function() return o:getSprite() and o:getSprite():getName() end) or U.try(function() return o:getSpriteName() end)
end

-- the blockers on a loaded square: [{obj, kind, index}]
function K.blockersOn(sq)
    local out = {}
    U.each(sq:getObjects(), function(o, i)
        local kind = CS.kindOf(spriteNameOf(o))
        if kind then out[#out + 1] = { obj = o, kind = kind, index = i } end
    end)
    return out
end

-- place one blocker of `kind` on a LOADED square; "placed" | "exists"
function K.placeOne(x, y, z, kind, name)
    kind = checkKind(kind)
    local sq = Z.square(x, y, z)
    local n, err = CS.ensure()
    if not n then error("collision sprites not registered: " .. tostring(err)) end
    for _, b in ipairs(K.blockersOn(sq)) do
        if b.kind == kind then
            local rec = store()[key(sq:getX(), sq:getY(), sq:getZ(), kind)]
            if rec and name then rec.name = name end
            return "exists"
        end
    end
    local obj = IsoObject.new(sq, CS.spriteName(kind), CS.OBJECT_NAME)
    sq:transmitAddObjectToSquare(obj, -1)
    store()[key(sq:getX(), sq:getY(), sq:getZ(), kind)] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), kind = kind, name = name, t = Z.now() }
    return "placed"
end

-- remove the blockers of `kind` (nil = every kind) from a LOADED square; returns how many objects went
function K.removeOn(sq, kind)
    local removed = 0
    local s = store()
    for _, b in ipairs(K.blockersOn(sq)) do
        if not kind or b.kind == kind then
            sq:transmitRemoveItemFromSquare(b.obj)
            s[key(sq:getX(), sq:getY(), sq:getZ(), b.kind)] = nil
            removed = removed + 1
        end
    end
    if not kind then
        -- registry entries for kinds whose object was already gone (remove_object) go too
        for _, k in ipairs(CS.ORDER) do s[key(sq:getX(), sq:getY(), sq:getZ(), k)] = nil end
    else
        s[key(sq:getX(), sq:getY(), sq:getZ(), kind)] = nil
    end
    return removed
end

-- iterate the rectangle x..x+w-1, y..y+h-1 at level z: fn(x, y, z, square|nil)
local function rect(a, fn)
    local x, y, z = U.pos(a)
    local w, h = U.int(a, "w", 1, 1, 50), U.int(a, "h", 1, 1, 50)
    if w * h > K.MAX_SQUARES then error("rectangle too large: " .. (w * h) .. " squares (max " .. K.MAX_SQUARES .. ")") end
    local cell = getCell()
    for dx = 0, w - 1 do
        for dy = 0, h - 1 do
            fn(x + dx, y + dy, z, cell:getGridSquare(x + dx, y + dy, z))
        end
    end
    return x, y, z, w, h
end

Z.tool("collision_place", "Place invisible blocking objects (players and zombies cannot walk through, pathing and line of sight respect them) on the rectangle x..x+w-1, y..y+h-1 at level z, or remove every blocker there (kind = remove). kind = solid (full square, blocks sight) | solidtrans (full square, see-through) | wall_n | wall_w | wall_nw (invisible wall on the north / west / both edges). Server-authoritative, saved with the world, synced to clients. args: {x, y, z?, w?, h?, kind, name?}. Returns {placed, existing, removed, unloaded, squares}.", function(a)
    local kind = checkKind(a.kind, true)
    local name = U.optStr(a, "name")
    local res = { kind = kind, placed = 0, existing = 0, removed = 0, unloaded = 0, squares = 0 }
    local unloaded = {}
    local x, y, z, w, h = rect(a, function(sx, sy, sz, sq)
        res.squares = res.squares + 1
        if not sq then
            res.unloaded = res.unloaded + 1
            if #unloaded < 20 then unloaded[#unloaded + 1] = { x = sx, y = sy, z = sz } end
        elseif kind == "remove" then
            res.removed = res.removed + K.removeOn(sq, nil)
        else
            local how = K.placeOne(sx, sy, sz, kind, name)
            if how == "placed" then res.placed = res.placed + 1 else res.existing = res.existing + 1 end
        end
    end)
    res.x, res.y, res.z, res.w, res.h = x, y, z, w, h
    if kind ~= "remove" then res.sprite = CS.spriteName(kind); res.blocks = CS.KINDS[kind].blocks end
    if res.unloaded > 0 then res.unloadedSquares = arr(unloaded); res.note = "unloaded squares were skipped (only areas near players are loaded)" end
    Z.event("collision_place", { kind = kind, x = x, y = y, z = z, w = w, h = h, placed = res.placed, removed = res.removed, unloaded = res.unloaded })
    return res
end)

-- registry entries near x,y,z (or all), reconciled with the loaded world: [{x, y, z, kind, name, t, loaded, present}]
function K.list(x, y, z, radius)
    local out, stale = {}, 0
    local cell = getCell()
    local s = store()
    local keys = {}
    for k in pairs(s) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local rec = s[k]
        local near = true
        if x then near = math.floor(rec.z) == math.floor(z) and math.abs(rec.x - x) <= radius and math.abs(rec.y - y) <= radius end
        if near then
            local sq = cell:getGridSquare(rec.x, rec.y, rec.z)
            local present = nil
            if sq then
                present = false
                for _, b in ipairs(K.blockersOn(sq)) do if b.kind == rec.kind then present = true end end
            end
            if present == false then
                s[k] = nil; stale = stale + 1          -- removed behind our back (remove_object, map reset)
            else
                out[#out + 1] = { x = rec.x, y = rec.y, z = rec.z, kind = rec.kind, name = rec.name, t = rec.t,
                    sprite = CS.spriteName(rec.kind), loaded = sq ~= nil, present = present }
            end
        end
    end
    return out, stale
end

Z.tool("collision_list", "List the invisible collision blockers placed by collision_place / model_place {collide}: [{x, y, z, kind, name, sprite, loaded, present}] (all of them, or within radius of x,y,z). Entries whose loaded square lost its blocker (remove_object) are dropped and counted as stale. Also returns the sprite names / ids (world_query shows blockers as sprite zmcp_collision_<kind>, name ZMCP_collision). args: {x?, y?, z?, radius?}", function(a)
    local x, y, z, radius
    if a.x ~= nil or a.y ~= nil then
        x, y, z = U.pos(a)
        radius = U.int(a, "radius", 10, 0, 200)
    end
    local list, stale = K.list(x, y, z, radius)
    return { blockers = arr(list), count = #list, stale = stale, sprites = arr(CS.info()), objectName = CS.OBJECT_NAME }
end)

Z.tool("collision_clear", "Remove collision blockers: all of them (all = true) or those within radius of x,y,z. Only loaded squares can be cleared; blockers on unloaded squares stay registered and are reported. args: {all?, x?, y?, z?, radius?}. Returns {removed, unloaded, remaining}.", function(a)
    local all = U.bool(a, "all", false)
    local x, y, z, radius
    if not all then
        if a.x == nil and a.y == nil then error("pass all = true or x, y (and radius)") end
        x, y, z = U.pos(a)
        radius = U.int(a, "radius", 10, 0, 200)
    end
    local list = K.list(x, y, z, radius)
    local res = { removed = 0, unloaded = 0 }
    local cell = getCell()
    local done = {}
    for _, rec in ipairs(list) do
        local sqKey = rec.x .. "," .. rec.y .. "," .. rec.z
        if not done[sqKey] then
            done[sqKey] = true
            local sq = cell:getGridSquare(rec.x, rec.y, rec.z)
            if sq then res.removed = res.removed + K.removeOn(sq, nil) else res.unloaded = res.unloaded + 1 end
        end
    end
    local remaining = K.list(nil)
    res.remaining = #remaining
    Z.event("collision_clear", { removed = res.removed, unloaded = res.unloaded, all = all })
    return res
end)

Z.event("collision_loaded", { version = K.version, sprites = CS.ensure() or 0 })
